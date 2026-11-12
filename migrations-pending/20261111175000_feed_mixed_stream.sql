CREATE TABLE public.feed_stream_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  viewer uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  stream text NOT NULL,
  format text NOT NULL,
  genre uuid,
  entries jsonb NOT NULL,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '20 minutes'
);
CREATE INDEX feed_stream_snapshots_expiry ON public.feed_stream_snapshots (expires_at);
ALTER TABLE public.feed_stream_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feed_stream_snapshots FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.feed_track_visible(track public.tracks)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT (track).is_public IS TRUE AND (track).status = 'completed'
    AND NOT coalesce((track).is_in_my_releases, false)
    AND (track).moderation_status IS DISTINCT FROM 'rejected';
$$;

CREATE FUNCTION public.feed_topic_visible(topic public.forum_topics, category public.forum_categories)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT NOT coalesce((topic).is_hidden, false) AND to_jsonb(topic)->>'hidden_at' IS NULL
    AND coalesce((category).is_active, true)
    AND NOT coalesce((to_jsonb(category)->>'is_hidden')::boolean, false);
$$;

CREATE FUNCTION public.feed_stream_author_visible(p_author uuid, p_track uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM public.feed_feedback feedback WHERE feedback.user_id = auth.uid()
      AND ((feedback.feedback_type = 'hide_author' AND feedback.author_id = p_author)
        OR (feedback.feedback_type = 'not_interested' AND feedback.track_id = p_track))
  );
$$;

CREATE FUNCTION public.feed_stream_entries(p_stream text, p_format text, p_genre uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH tracks AS (
    SELECT 'track' AS kind, track.id, track.created_at AS sort_at,
      CASE WHEN p_stream = 'following' THEN 'following' ELSE 'fresh' END AS reason,
      extract(epoch FROM track.created_at) AS rank
    FROM public.tracks track
    WHERE p_stream IN ('fresh', 'following') AND p_format IN ('all', 'track')
      AND public.feed_track_visible(track) AND (p_genre IS NULL OR track.genre_id = p_genre)
      AND public.feed_stream_author_visible(track.user_id, track.id)
      AND (p_stream = 'fresh' OR EXISTS (SELECT 1 FROM public.user_follows f
        WHERE f.follower_id = auth.uid() AND f.following_id = track.user_id))
    UNION ALL
    SELECT 'track', track.id, track.created_at, smart.recommendation_reason,
      CASE WHEN p_stream IN ('main', 'trending') THEN 1000.0 - smart.ordinality * 3 ELSE 1000.0 - smart.ordinality END
    FROM (SELECT p_stream AS stream WHERE p_stream IN ('main', 'trending', 'deep') AND p_format IN ('all', 'track')) mode
    CROSS JOIN LATERAL public.get_smart_feed_v3(auth.uid(), mode.stream, p_genre, 0, 500) WITH ORDINALITY smart
    JOIN public.tracks track ON track.id = smart.id
    WHERE public.feed_track_visible(track) AND public.feed_stream_author_visible(track.user_id, track.id)
  ), post_activity AS (
    SELECT post_id, count(DISTINCT actor) AS participants FROM (
      SELECT post_id, author_id AS actor FROM public.feed_post_replies WHERE p_stream = 'trending' AND created_at >= now() - interval '24 hours'
      UNION ALL
      SELECT post_id, user_id FROM public.feed_post_bookmarks WHERE p_stream = 'trending' AND created_at >= now() - interval '24 hours'
    ) activity JOIN public.feed_posts post ON post.id = activity.post_id AND post.author_id <> activity.actor
    GROUP BY post_id
  ), forum_activity AS (
    SELECT reply.topic_id, count(DISTINCT reply.user_id) AS participants
    FROM public.forum_posts reply JOIN public.forum_topics topic ON topic.id = reply.topic_id
    WHERE p_stream = 'trending' AND reply.created_at >= now() - interval '24 hours'
      AND NOT coalesce(reply.is_hidden, false) AND reply.user_id <> topic.user_id
    GROUP BY reply.topic_id
  ), posts AS (
    SELECT post.id, activity.participants,
      CASE WHEN p_stream = 'saved' THEN bookmark.created_at ELSE post.created_at END AS sort_at,
      CASE p_stream WHEN 'following' THEN 'following' WHEN 'saved' THEN 'saved'
        WHEN 'trending' THEN 'trending' ELSE 'fresh' END AS reason
    FROM public.feed_posts post
    LEFT JOIN public.feed_post_bookmarks bookmark ON bookmark.post_id = post.id AND bookmark.user_id = auth.uid()
    LEFT JOIN public.tracks attachment ON attachment.id = post.track_id AND public.feed_track_visible(attachment)
    LEFT JOIN post_activity activity ON activity.post_id = post.id
    WHERE post.hidden_at IS NULL AND public.feed_stream_author_visible(post.author_id)
      AND p_format IN ('all', 'post', post.kind)
      AND (p_genre IS NULL OR post.genre_id = p_genre OR attachment.genre_id = p_genre)
      AND (p_stream IN ('main','fresh') OR (p_stream = 'saved' AND bookmark.post_id IS NOT NULL)
        OR (p_stream = 'trending' AND activity.participants > 0)
        OR (p_stream = 'following' AND EXISTS (SELECT 1 FROM public.user_follows f
          WHERE f.follower_id = auth.uid() AND f.following_id = post.author_id)))
      AND (p_stream <> 'main' OR post.kind <> 'collaboration' OR post.closed_at IS NULL)
  ), topics AS (
    SELECT topic.id, topic.created_at, topic.last_post_at, activity.participants,
      CASE WHEN p_stream = 'following' THEN 'following' ELSE 'discussion' END AS reason
    FROM public.forum_topics topic JOIN public.forum_categories category ON category.id = topic.category_id
    LEFT JOIN forum_activity activity ON activity.topic_id = topic.id
    WHERE p_stream IN ('main', 'fresh', 'following', 'trending') AND p_format IN ('all', 'forum') AND p_genre IS NULL
      AND public.feed_topic_visible(topic, category) AND public.feed_stream_author_visible(topic.user_id)
      AND (p_stream <> 'trending' OR activity.participants > 0)
      AND (p_stream <> 'main' OR coalesce(topic.last_post_at, topic.created_at) >= now() - interval '30 days')
      AND (p_stream <> 'following' OR EXISTS (SELECT 1 FROM public.user_follows f
        WHERE f.follower_id = auth.uid() AND f.following_id = topic.user_id))
  ), combined AS (
    SELECT * FROM tracks
    UNION ALL
    SELECT 'post', id, sort_at, reason, CASE WHEN p_stream IN ('main', 'trending')
      THEN 999 - row_number() OVER (ORDER BY participants DESC NULLS LAST, sort_at DESC, id DESC) * 3 ELSE extract(epoch FROM sort_at) END
    FROM posts
    UNION ALL
    SELECT 'forum', id, created_at, reason, CASE WHEN p_stream IN ('main', 'trending')
      THEN 998 - row_number() OVER (ORDER BY participants DESC NULLS LAST, coalesce(last_post_at, created_at) DESC, id DESC) * 3
      ELSE extract(epoch FROM created_at) END
    FROM topics
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('type', kind, 'id', id, 'reason', reason)
    ORDER BY rank DESC, sort_at DESC, kind, id DESC), '[]'::jsonb)
  FROM (
    SELECT * FROM (SELECT DISTINCT ON (kind, id) * FROM combined ORDER BY kind, id, rank DESC, sort_at DESC) unique_entries
    ORDER BY rank DESC, sort_at DESC, kind, id DESC LIMIT 500
  ) ordered;
$$;

CREATE FUNCTION public.feed_stream_preview(p_type text, p_id uuid, p_reason text, p_stream text, p_genre uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE preview jsonb; format text; actions text[]; author uuid;
BEGIN
  CASE p_type
  WHEN 'track' THEN
    SELECT jsonb_build_object(
      'id', t.id, 'title', t.title, 'description', t.description, 'audio_url', t.audio_url, 'cover_url', t.cover_url,
      'duration', t.duration, 'user_id', t.user_id, 'genre_id', t.genre_id, 'is_public', true,
      'likes_count', t.likes_count, 'plays_count', t.plays_count,
      'comments_count', (SELECT count(*) FROM public.track_comments WHERE track_id = t.id),
      'shares_count', t.shares_count, 'saves_count', (SELECT count(*) FROM public.playlist_tracks WHERE track_id = t.id),
      'status', t.status, 'created_at', t.created_at,
      'profile', jsonb_build_object('username', p.username, 'display_name', p.display_name, 'avatar_url', p.avatar_url),
      'genre', CASE WHEN g.id IS NOT NULL THEN jsonb_build_object('id', g.id, 'name_ru', g.name_ru) END,
      'author_tier', coalesce(stats.tier, 'newcomer'), 'author_tier_icon', tier.icon, 'author_tier_color', tier.color,
      'author_verified', coalesce(p.is_verified, false), 'feed_score', coalesce(score.final_score, 0),
      'feed_velocity', coalesce(score.velocity_24h, 0), 'quality_score', coalesce(quality.quality_score, 5),
      'author_sub_tier', plan.tier_key, 'author_sub_badge', plan.badge_emoji,
      'is_boosted', promotion.expires_at IS NOT NULL, 'boost_expires_at', promotion.expires_at,
      'recommendation_reason', p_reason
    ), t.user_id INTO preview, author
    FROM public.tracks t LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats stats ON stats.user_id = t.user_id
    LEFT JOIN public.reputation_tiers tier ON tier.key = coalesce(stats.tier, 'newcomer')
    LEFT JOIN public.track_feed_scores score ON score.track_id = t.id
    LEFT JOIN public.track_quality_scores quality ON quality.track_id = t.id
    LEFT JOIN LATERAL (SELECT expires_at FROM public.track_promotions
      WHERE track_id = t.id AND is_active AND expires_at > now() ORDER BY expires_at DESC LIMIT 1) promotion ON true
    LEFT JOIN LATERAL (SELECT plan_id FROM public.user_subscriptions
      WHERE user_id = t.user_id AND status = 'active' AND current_period_end > now()
      ORDER BY created_at DESC LIMIT 1) subscription ON true
    LEFT JOIN public.subscription_plans plan ON plan.id = subscription.plan_id
    WHERE t.id = p_id AND public.feed_track_visible(t) AND public.feed_stream_author_visible(t.user_id, t.id)
      AND (p_genre IS NULL OR t.genre_id = p_genre);
    format := 'track';
    actions := ARRAY['open','play'];
    IF auth.uid() IS NOT NULL THEN actions := actions || ARRAY['like','comment','feedback']; END IF;
  WHEN 'post' THEN
    SELECT jsonb_build_object(
      'id', p.id, 'author_id', p.author_id, 'body', p.body, 'created_at', p.created_at,
      'author_name', coalesce(profile.display_name, profile.username, 'Автор'), 'avatar_url', profile.avatar_url,
      'saved', bookmark.post_id IS NOT NULL, 'sort_at', coalesce(bookmark.created_at, p.created_at),
      'reply_count', (SELECT count(*) FROM public.feed_post_replies reply WHERE reply.post_id = p.id),
      'details', public.feed_public_post_details(p)
    ), p.kind, p.author_id INTO preview, format, author
    FROM public.feed_posts p LEFT JOIN public.profiles profile ON profile.user_id = p.author_id
    LEFT JOIN public.feed_post_bookmarks bookmark ON bookmark.post_id = p.id AND bookmark.user_id = auth.uid()
    LEFT JOIN public.tracks attachment ON attachment.id = p.track_id AND public.feed_track_visible(attachment)
    WHERE p.id = p_id AND p.hidden_at IS NULL AND public.feed_stream_author_visible(p.author_id)
      AND (p_stream <> 'main' OR p.kind <> 'collaboration' OR p.closed_at IS NULL)
      AND (p_genre IS NULL OR p.genre_id = p_genre OR attachment.genre_id = p_genre)
      AND (p_stream <> 'saved' OR bookmark.post_id IS NOT NULL);
    actions := ARRAY['open'];
    IF auth.uid() IS NOT NULL THEN
      actions := actions || ARRAY['reply','save'] || CASE WHEN auth.uid() = author THEN ARRAY['edit','delete'] ELSE ARRAY['follow','report'] END;
    END IF;
  WHEN 'forum' THEN
    SELECT jsonb_build_object('id', topic.id, 'title', topic.title, 'category', category.name_ru,
      'reply_count', greatest(coalesce(topic.posts_count, 1) - 1, 0),
      'last_post_at', topic.last_post_at, 'created_at', topic.created_at), topic.user_id INTO preview, author
    FROM public.forum_topics topic JOIN public.forum_categories category ON category.id = topic.category_id
    WHERE topic.id = p_id AND public.feed_topic_visible(topic, category) AND public.feed_stream_author_visible(topic.user_id);
    format := 'forum';
    actions := ARRAY['open'];
  ELSE RETURN NULL;
  END CASE;
  IF preview IS NULL OR (p_stream = 'following' AND NOT EXISTS (
    SELECT 1 FROM public.user_follows f WHERE f.follower_id = auth.uid() AND f.following_id = author
  )) THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('type', p_type, 'format', format, 'key', p_type || ':' || p_id,
    'source', jsonb_build_object('type', p_type, 'id', p_id), 'createdAt', preview->'created_at',
    'actions', actions, 'reason', p_reason, 'preview', preview);
END;
$$;

CREATE FUNCTION public.feed_read_stream(
  p_stream text, p_format text DEFAULT 'all', p_genre uuid DEFAULT NULL,
  p_cursor text DEFAULT NULL, p_limit integer DEFAULT 20
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  snapshot public.feed_stream_snapshots;
  cursor_data text;
  position integer := 0;
  page_size integer := least(20, greatest(1, coalesce(p_limit, 20)));
  items jsonb;
  last_position integer;
  more boolean;
BEGIN
  IF p_stream IS NULL OR p_stream NOT IN ('main','fresh','following','trending','deep','saved')
    OR p_format IS NULL OR p_format NOT IN ('all','track','post','news','feedback','collaboration','forum')
  THEN RAISE EXCEPTION 'INVALID_FEED_FILTER'; END IF;
  IF p_cursor IS NULL THEN
    DELETE FROM public.feed_stream_snapshots WHERE id IN (
      SELECT id FROM public.feed_stream_snapshots WHERE expires_at <= now() ORDER BY expires_at LIMIT 250 FOR UPDATE SKIP LOCKED
    );
    INSERT INTO public.feed_stream_snapshots(viewer, stream, format, genre, entries)
    VALUES (auth.uid(), p_stream, p_format, p_genre, public.feed_stream_entries(p_stream, p_format, p_genre))
    RETURNING * INTO snapshot;
  ELSE
    IF length(p_cursor) > 100 THEN RAISE EXCEPTION 'FEED_CURSOR_EXPIRED'; END IF;
    BEGIN
      cursor_data := convert_from(decode(p_cursor, 'base64'), 'UTF8');
      IF cursor_data !~ '^[0-9a-f-]{36}:[0-9]{1,3}$' THEN RAISE EXCEPTION 'FEED_CURSOR_EXPIRED'; END IF;
      position := split_part(cursor_data, ':', 2)::integer;
      SELECT * INTO snapshot FROM public.feed_stream_snapshots
      WHERE id = split_part(cursor_data, ':', 1)::uuid AND expires_at > now() AND viewer IS NOT DISTINCT FROM auth.uid()
        AND stream = p_stream AND format = p_format AND genre IS NOT DISTINCT FROM p_genre;
      IF NOT FOUND OR (position > 0 AND position >= jsonb_array_length(snapshot.entries))
      THEN RAISE EXCEPTION 'FEED_CURSOR_EXPIRED'; END IF;
    EXCEPTION WHEN data_exception THEN RAISE EXCEPTION 'FEED_CURSOR_EXPIRED';
    END;
  END IF;
  WITH visible AS MATERIALIZED (
    SELECT entry.ordinality, item.value FROM jsonb_array_elements(snapshot.entries) WITH ORDINALITY entry
    CROSS JOIN LATERAL (SELECT public.feed_stream_preview(entry.value->>'type', (entry.value->>'id')::uuid,
      entry.value->>'reason', p_stream, p_genre) AS value OFFSET 0) item
    WHERE entry.ordinality > position AND item.value IS NOT NULL
      AND (p_format = 'all' OR item.value->>'type' = p_format OR item.value->>'format' = p_format)
    ORDER BY entry.ordinality LIMIT page_size + 1
  ), numbered AS (
    SELECT *, row_number() OVER (ORDER BY ordinality) AS number FROM visible
  )
  SELECT coalesce(jsonb_agg(value ORDER BY ordinality) FILTER (WHERE number <= page_size), '[]'::jsonb),
    max(ordinality) FILTER (WHERE number <= page_size), count(*) > page_size
  INTO items, last_position, more FROM numbered;
  RETURN jsonb_build_object('items', items,
    'startCursor', encode(convert_to(snapshot.id::text || ':0', 'UTF8'), 'base64'),
    'nextCursor', CASE WHEN more THEN encode(convert_to(snapshot.id::text || ':' || last_position, 'UTF8'), 'base64') END);
END;
$$;

REVOKE ALL ON FUNCTION public.feed_track_visible(public.tracks),
  public.feed_topic_visible(public.forum_topics,public.forum_categories), public.feed_stream_author_visible(uuid,uuid),
  public.feed_stream_entries(text,text,uuid), public.feed_stream_preview(text,uuid,text,text,uuid),
  public.feed_read_stream(text,text,uuid,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_read_stream(text,text,uuid,text,integer) TO anon, authenticated;
