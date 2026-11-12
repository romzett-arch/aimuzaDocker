CREATE TABLE public.feed_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  reporter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN ('spam','abuse','rights','other')),
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  UNIQUE (post_id, reporter_id)
);
CREATE INDEX feed_reports_pending ON public.feed_reports (created_at) WHERE resolved_at IS NULL;
CREATE TABLE public.feed_moderation_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  moderator_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decision text NOT NULL CHECK (decision IN ('keep','hide','restore')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX feed_moderation_recent ON public.feed_moderation_log (created_at DESC, id DESC);

CREATE TABLE public.feed_events (
  event text NOT NULL CHECK (event IN ('impression','qualified_listen','publish','reply','save','follow','report','hide')),
  subject uuid NOT NULL,
  event_key uuid NOT NULL,
  actor uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  stream text NOT NULL DEFAULT coalesce(nullif(current_setting('feed.stream', true), ''), 'unknown'),
  device text NOT NULL DEFAULT coalesce(nullif(current_setting('feed.device', true), ''), 'unknown'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event, subject, event_key)
);
CREATE INDEX feed_events_recent ON public.feed_events (created_at DESC);
ALTER TABLE public.feed_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_moderation_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feed_reports, public.feed_moderation_log, public.feed_events FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.feed_report_post(p_post uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid(); report_id uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 27));
  PERFORM 1 FROM public.feed_posts WHERE id = p_post AND hidden_at IS NULL AND author_id <> actor FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
  IF (SELECT count(*) FROM public.feed_reports WHERE reporter_id = actor AND created_at >= now() - interval '1 day') >= 15
  THEN RAISE EXCEPTION 'REPORT_LIMIT'; END IF;
  INSERT INTO public.feed_reports(post_id, reporter_id, reason) VALUES (p_post, actor, p_reason)
    ON CONFLICT DO NOTHING RETURNING id INTO report_id;
  IF report_id IS NOT NULL THEN
    INSERT INTO public.feed_events(event, subject, event_key, actor) VALUES ('report', p_post, report_id, actor);
  END IF;
END;
$$;

CREATE FUNCTION public.admin_feed_moderate(p_post uuid, p_decision text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE post public.feed_posts;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'ADMIN_REQUIRED'; END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('keep','hide','restore') THEN RAISE EXCEPTION 'INVALID_DECISION'; END IF;
  SELECT * INTO post FROM public.feed_posts WHERE id = p_post FOR UPDATE;
  IF NOT FOUND OR post.author_deleted OR (post.hidden_at IS NOT NULL AND NOT post.moderation_hidden)
  THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
  IF p_decision = 'hide' AND NOT post.moderation_hidden THEN
    UPDATE public.feed_posts SET hidden_at = now(), moderation_hidden = true WHERE id = p_post;
    INSERT INTO public.notifications(user_id, actor_id, type, title, target_type, target_id)
      VALUES (post.author_id, auth.uid(), 'system', 'Ваша публикация скрыта модератором', 'feed_post', p_post);
    INSERT INTO public.feed_events(event, subject, event_key, actor) VALUES ('hide', p_post, gen_random_uuid(), auth.uid());
  ELSIF p_decision = 'restore' AND post.moderation_hidden THEN
    UPDATE public.feed_posts SET hidden_at = NULL, moderation_hidden = false WHERE id = p_post;
  ELSIF p_decision <> 'keep' THEN RETURN;
  END IF;
  UPDATE public.feed_reports SET resolved_at = now() WHERE post_id = p_post AND resolved_at IS NULL;
  IF p_decision = 'keep' AND NOT FOUND THEN RETURN; END IF;
  INSERT INTO public.feed_moderation_log(post_id, moderator_id, decision)
    VALUES (p_post, auth.uid(), p_decision);
END;
$$;

CREATE FUNCTION public.admin_feed_review(p_view text, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'ADMIN_REQUIRED'; END IF;
  IF p_view = 'history' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC, row.id DESC), '[]') INTO result
    FROM (SELECT log.id, log.post_id, log.decision, log.created_at, log.moderator_id
      FROM public.feed_moderation_log log ORDER BY log.created_at DESC, log.id DESC
      LIMIT 25 OFFSET greatest(p_offset, 0)) row;
  ELSE
    SELECT coalesce(jsonb_agg(to_jsonb(row) ORDER BY row.created_at, row.id), '[]') INTO result FROM (
      SELECT post.id, post.author_id, post.body, post.created_at, post.moderation_hidden AS hidden,
        public.feed_public_post_details(post) AS details,
        ARRAY(SELECT report.reason FROM public.feed_reports report WHERE report.post_id = post.id AND report.resolved_at IS NULL ORDER BY report.created_at) AS reasons
      FROM public.feed_posts post
      WHERE NOT post.author_deleted AND (CASE WHEN p_view = 'hidden' THEN post.moderation_hidden ELSE
        post.hidden_at IS NULL AND EXISTS (SELECT 1 FROM public.feed_reports report WHERE report.post_id = post.id AND report.resolved_at IS NULL)
      END)
      ORDER BY post.created_at, post.id LIMIT 25 OFFSET greatest(p_offset, 0)) row;
  END IF;
  RETURN result;
END;
$$;

CREATE FUNCTION public.feed_record_event(p_event text, p_subject uuid, p_session uuid, p_stream text, p_device text, p_seconds integer DEFAULT 0)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid(); valid_subject boolean;
BEGIN
  IF p_event NOT IN ('impression','qualified_listen','follow') OR p_session IS NULL
    OR p_stream NOT IN ('main','fresh','following','trending','deep','saved','post','unknown')
    OR p_device NOT IN ('desktop','mobile') THEN RETURN; END IF;
  IF p_event = 'qualified_listen' THEN
    SELECT EXISTS(SELECT 1 FROM public.tracks WHERE id = p_subject AND is_public IS TRUE AND status = 'completed'
      AND duration > 0 AND p_seconds >= least(15, ceil(duration / 2.0))
      AND (actor IS NULL OR user_id <> actor)) INTO valid_subject;
  ELSIF p_event = 'follow' THEN
    SELECT EXISTS(SELECT 1 FROM public.user_follows WHERE follower_id = actor AND following_id = p_subject) INTO valid_subject;
  ELSE
    SELECT EXISTS(SELECT 1 FROM public.feed_posts WHERE id = p_subject AND hidden_at IS NULL)
      OR EXISTS(SELECT 1 FROM public.tracks WHERE id = p_subject AND is_public IS TRUE AND status = 'completed') INTO valid_subject;
  END IF;
  IF valid_subject THEN
    INSERT INTO public.feed_events(event, subject, event_key, actor, stream, device)
    VALUES (p_event, p_subject, p_session, actor, p_stream, p_device) ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE FUNCTION public.feed_capture_write()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_TABLE_NAME = 'feed_posts' THEN
    INSERT INTO public.feed_events(event, subject, event_key, actor) VALUES ('publish', NEW.id, NEW.id, NEW.author_id);
  ELSIF TG_TABLE_NAME = 'feed_post_replies' THEN
    INSERT INTO public.feed_events(event, subject, event_key, actor) VALUES ('reply', NEW.post_id, NEW.id, NEW.author_id);
  ELSE
    INSERT INTO public.feed_events(event, subject, event_key, actor) VALUES ('save', NEW.post_id, NEW.user_id, NEW.user_id) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER feed_publish_event AFTER INSERT ON public.feed_posts FOR EACH ROW EXECUTE FUNCTION public.feed_capture_write();
CREATE TRIGGER feed_reply_event AFTER INSERT ON public.feed_post_replies FOR EACH ROW EXECUTE FUNCTION public.feed_capture_write();
CREATE TRIGGER feed_save_event AFTER INSERT ON public.feed_post_bookmarks FOR EACH ROW EXECUTE FUNCTION public.feed_capture_write();

CREATE FUNCTION public.admin_feed_analytics(p_days integer DEFAULT 14)
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
      'requests', (SELECT count(*) FROM answered),
      'answered', (SELECT count(*) FROM answered WHERE has_answer)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.feed_report_post(uuid,text), public.admin_feed_moderate(uuid,text),
  public.admin_feed_review(text,integer), public.feed_record_event(text,uuid,uuid,text,text,integer),
  public.feed_capture_write(), public.admin_feed_analytics(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_report_post(uuid,text), public.admin_feed_moderate(uuid,text),
  public.admin_feed_review(text,integer), public.admin_feed_analytics(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.feed_record_event(text,uuid,uuid,text,text,integer) TO anon, authenticated;
