CREATE INDEX feed_events_visitor_date ON public.feed_events (actor, created_at)
  WHERE event = 'impression' AND actor IS NOT NULL;

CREATE OR REPLACE FUNCTION public.admin_feed_analytics(p_days integer DEFAULT 14)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE since timestamptz := now() - make_interval(days => least(90, greatest(1, p_days)));
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'ADMIN_REQUIRED'; END IF;
  RETURN (
    WITH events AS (
      SELECT event.*, CASE WHEN event.actor IS NULL THEN 'guest'
        WHEN event.created_at < account.created_at + interval '7 days' THEN 'new' ELSE 'established' END AS account_age
      FROM public.feed_events event LEFT JOIN auth.users account ON account.id = event.actor WHERE event.created_at >= since
    ), segments AS (
      SELECT event, stream, device, account_age, count(*) AS total FROM events GROUP BY 1,2,3,4
    ), visitors AS (
      SELECT DISTINCT actor FROM events WHERE event = 'impression' AND actor IS NOT NULL AND created_at >= now() - interval '7 days'
    ), first_visits AS (
      SELECT actor, min((created_at AT TIME ZONE 'UTC')::date) AS first_day
      FROM public.feed_events WHERE event = 'impression' AND actor IS NOT NULL GROUP BY actor
    ), return_cohort AS (
      SELECT visitor.actor, EXISTS (
        SELECT 1 FROM public.feed_events event WHERE event.event = 'impression' AND event.actor = visitor.actor
          AND event.created_at >= ((visitor.first_day + 7)::timestamp AT TIME ZONE 'UTC')
          AND event.created_at < ((visitor.first_day + 8)::timestamp AT TIME ZONE 'UTC')
      ) AS returned
      FROM first_visits visitor
      WHERE visitor.first_day >= (since AT TIME ZONE 'UTC')::date
        AND visitor.first_day < (now() AT TIME ZONE 'UTC')::date - 7
    ), answered AS (
      SELECT post.id, EXISTS (SELECT 1 FROM public.feed_post_replies reply WHERE reply.post_id = post.id
        AND reply.author_id <> post.author_id AND reply.created_at <= post.created_at + interval '48 hours') AS has_answer
      FROM public.feed_posts post WHERE post.kind IN ('feedback','collaboration') AND post.hidden_at IS NULL
        AND post.created_at BETWEEN since AND now() - interval '48 hours'
    )
    SELECT jsonb_build_object(
      'segments', (SELECT coalesce(jsonb_agg(to_jsonb(segments) ORDER BY event, stream, device, account_age), '[]') FROM segments),
      'weekly_visitors', (SELECT count(*) FROM visitors),
      'weekly_engaged', (SELECT count(*) FROM visitors v WHERE EXISTS (SELECT 1 FROM events e WHERE e.actor = v.actor
        AND e.created_at >= now() - interval '7 days' AND e.event IN ('reply','save','follow','publish'))),
      'return_cohort', (SELECT count(*) FROM return_cohort),
      'returned_on_day_7', (SELECT count(*) FROM return_cohort WHERE returned),
      'requests', (SELECT count(*) FROM answered),
      'answered', (SELECT count(*) FROM answered WHERE has_answer)
    )
  );
END;
$$;
