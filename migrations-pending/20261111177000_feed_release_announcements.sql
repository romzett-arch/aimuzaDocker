ALTER TABLE public.feed_posts ADD COLUMN is_release_announcement boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX feed_release_announcement_per_track ON public.feed_posts(track_id)
  WHERE is_release_announcement AND NOT author_deleted AND track_id IS NOT NULL;
ALTER TABLE public.feed_posts ADD CONSTRAINT feed_release_announcement_is_news
  CHECK (NOT is_release_announcement OR kind = 'news');

CREATE FUNCTION public.feed_release_target(p_track uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', track.id, 'title', track.title, 'duration', track.duration,
    'announcementId', announcement.id, 'announcementHidden', announcement.hidden_at IS NOT NULL)
  FROM public.tracks track
  LEFT JOIN public.feed_posts announcement ON announcement.track_id = track.id
    AND announcement.is_release_announcement AND NOT announcement.author_deleted
  WHERE track.id = p_track AND track.user_id = auth.uid() AND public.feed_track_visible(track)
    AND nullif(btrim(track.audio_url), '') IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.feed_release_target(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_release_target(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.feed_save_post(p_id uuid, p_body text, p_details jsonb, p_edit boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor uuid := auth.uid();
  format text := coalesce(p_details->>'kind', 'news');
  title text := nullif(btrim(p_details->>'headline'), '');
  genre uuid := nullif(p_details->>'genre_id', '')::uuid;
  requested_role text := nullif(p_details->>'collaboration_role', '');
  attached_track uuid := nullif(p_details->>'track_id', '')::uuid;
  cue integer := nullif(p_details->>'cue_seconds', '')::integer;
  images jsonb := coalesce(p_details->'images', '[]');
  image_item record;
  labels text[];
  announcement boolean := coalesce((p_details->>'release_announcement')::boolean, false);
  existing public.feed_posts;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 24));
  IF NOT p_edit AND EXISTS (SELECT 1 FROM public.feed_posts WHERE id = p_id AND author_id = actor AND hidden_at IS NULL)
  THEN RETURN p_id; END IF;
  IF p_edit THEN
    SELECT * INTO existing FROM public.feed_posts WHERE id = p_id AND author_id = actor AND hidden_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
    announcement := existing.is_release_announcement;
    IF announcement THEN
      format := 'news';
      attached_track := existing.track_id;
    END IF;
  ELSIF announcement THEN
    IF format <> 'news' OR attached_track IS NULL OR public.feed_release_target(attached_track) IS NULL
    THEN RAISE EXCEPTION 'TRACK_UNAVAILABLE'; END IF;
    IF EXISTS (SELECT 1 FROM public.feed_posts WHERE track_id = attached_track AND is_release_announcement AND NOT author_deleted)
    THEN RAISE EXCEPTION 'RELEASE_ALREADY_ANNOUNCED'; END IF;
  END IF;
  IF format NOT IN ('news','feedback','collaboration')
    OR (format = 'feedback' AND (title IS NULL OR attached_track IS NULL))
    OR (format = 'collaboration' AND (genre IS NULL OR requested_role IS NULL))
    OR (cue IS NOT NULL AND (cue < 0 OR format <> 'feedback'))
    OR jsonb_typeof(images) <> 'array' OR jsonb_array_length(images) > 4
  THEN RAISE EXCEPTION 'INVALID_POST_DETAILS'; END IF;
  IF attached_track IS NOT NULL AND NOT (p_edit AND announcement) AND NOT EXISTS (
    SELECT 1 FROM public.tracks WHERE id = attached_track AND user_id = actor AND is_public IS TRUE
      AND status = 'completed' AND moderation_status IS DISTINCT FROM 'rejected'
      AND audio_url IS NOT NULL AND (cue IS NULL OR cue < duration)
  ) THEN RAISE EXCEPTION 'TRACK_UNAVAILABLE'; END IF;
  SELECT coalesce(array_agg(DISTINCT btrim(value)), '{}') INTO labels
  FROM jsonb_array_elements_text(coalesce(p_details->'tags', '[]')) tags(value) WHERE btrim(value) <> '';
  IF cardinality(labels) > 3 OR EXISTS (SELECT 1 FROM unnest(labels) label WHERE char_length(label) > 32)
  THEN RAISE EXCEPTION 'INVALID_TAGS'; END IF;

  PERFORM public.feed_write_post(p_id, p_body, p_edit);
  UPDATE public.feed_posts SET kind = format, headline = title,
    genre_id = CASE WHEN format = 'collaboration' THEN genre END,
    collaboration_role = CASE WHEN format = 'collaboration' THEN requested_role END,
    closed_at = CASE WHEN format = 'collaboration' AND kind = format THEN closed_at END,
    track_id = attached_track, cue_seconds = cue, tags = labels, is_release_announcement = announcement
    WHERE id = p_id AND author_id = actor AND hidden_at IS NULL;

  UPDATE public.feed_images SET position = NULL WHERE post_id = p_id;
  FOR image_item IN SELECT value, ordinality FROM jsonb_array_elements(images) WITH ORDINALITY LOOP
    UPDATE public.feed_images SET post_id = p_id, position = image_item.ordinality,
      alt = coalesce(image_item.value->>'alt', '')
    WHERE id = (image_item.value->>'id')::uuid AND author_id = actor AND position IS NULL
      AND (post_id = p_id OR post_id IS NULL);
    IF NOT FOUND THEN RAISE EXCEPTION 'IMAGE_UNAVAILABLE'; END IF;
  END LOOP;
  DELETE FROM public.feed_images WHERE post_id = p_id AND position IS NULL;
  RETURN p_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.feed_public_post_details(p_post public.feed_posts)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'kind', p_post.kind, 'release_announcement', p_post.is_release_announcement,
    'release_track', CASE WHEN p_post.is_release_announcement THEN
      public.feed_stream_preview('track', p_post.track_id, NULL, 'fresh', NULL)->'preview' END, 'headline', p_post.headline, 'genre_id', p_post.genre_id,
    'genre', (SELECT name_ru FROM public.genres WHERE id = p_post.genre_id),
    'collaboration_role', p_post.collaboration_role, 'closed_at', p_post.closed_at, 'tags', p_post.tags,
    'images', coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'alt', alt) ORDER BY position)
      FROM public.feed_images WHERE post_id = p_post.id), '[]'::jsonb),
    'track', (SELECT jsonb_build_object('id', track.id, 'title', track.title, 'audio_url', track.audio_url,
      'cover_url', track.cover_url, 'duration', track.duration, 'cue_seconds', p_post.cue_seconds)
      FROM public.tracks track WHERE track.id = p_post.track_id AND track.is_public IS TRUE
      AND track.status = 'completed' AND track.moderation_status IS DISTINCT FROM 'rejected' AND track.audio_url IS NOT NULL)
  );
$$;

CREATE OR REPLACE FUNCTION public.feed_stream_entries(p_stream text, p_format text, p_genre uuid)
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
    SELECT post.id, activity.participants, CASE WHEN post.is_release_announcement THEN attachment.id END AS announced_track,
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
    SELECT CASE WHEN announcement.id IS NULL THEN 'track' ELSE 'post' END AS kind,
      coalesce(announcement.id, tracks.id) AS id, coalesce(announcement.sort_at, tracks.sort_at) AS sort_at,
      coalesce(announcement.reason, tracks.reason) AS reason,
      CASE WHEN announcement.id IS NOT NULL AND p_stream IN ('fresh', 'following')
        THEN extract(epoch FROM announcement.sort_at) ELSE tracks.rank END AS rank
    FROM tracks LEFT JOIN posts announcement ON announcement.announced_track = tracks.id
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
