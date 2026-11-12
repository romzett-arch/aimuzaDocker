ALTER TABLE public.feed_posts
  ADD COLUMN kind text NOT NULL DEFAULT 'news' CHECK (kind IN ('news', 'feedback', 'collaboration')),
  ADD COLUMN headline text CHECK (char_length(headline) BETWEEN 1 AND 120),
  ADD COLUMN genre_id uuid REFERENCES public.genres(id) ON DELETE SET NULL,
  ADD COLUMN collaboration_role text CHECK (collaboration_role IN ('vocals', 'lyrics', 'arrangement', 'mixing', 'other')),
  ADD COLUMN closed_at timestamptz,
  ADD COLUMN track_id uuid REFERENCES public.tracks(id) ON DELETE SET NULL,
  ADD COLUMN cue_seconds integer CHECK (cue_seconds >= 0),
  ADD COLUMN moderation_hidden boolean NOT NULL DEFAULT false,
  ADD COLUMN author_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN tags text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 3);

CREATE TABLE public.feed_images (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  post_id uuid REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  position integer CHECK (position BETWEEN 1 AND 4),
  mime text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  content bytea NOT NULL CHECK (octet_length(content) BETWEEN 16 AND 163840),
  alt text NOT NULL DEFAULT '' CHECK (char_length(alt) <= 250),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (post_id, position)
);
CREATE INDEX feed_images_author_date ON public.feed_images (author_id, created_at);
ALTER TABLE public.feed_images ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feed_images FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.feed_upload_image(p_id uuid, p_data text, p_mime text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid(); bytes bytea;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_data IS NULL OR char_length(p_data) > 218456 THEN RAISE EXCEPTION 'IMAGE_SIZE'; END IF;
  bytes := decode(p_data, 'base64');
  IF octet_length(bytes) NOT BETWEEN 16 AND 163840 OR NOT coalesce(
    (p_mime = 'image/jpeg' AND substring(bytes FROM 1 FOR 3) = decode('ffd8ff','hex'))
    OR (p_mime = 'image/png' AND substring(bytes FROM 1 FOR 8) = decode('89504e470d0a1a0a','hex'))
    OR (p_mime = 'image/webp' AND substring(bytes FROM 1 FOR 4) = decode('52494646','hex')
        AND substring(bytes FROM 9 FOR 4) = decode('57454250','hex')), false)
  THEN RAISE EXCEPTION 'IMAGE_FORMAT'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 26));
  IF EXISTS (SELECT 1 FROM public.feed_images WHERE id = p_id AND author_id = actor) THEN RETURN p_id; END IF;
  DELETE FROM public.feed_images WHERE author_id = actor AND post_id IS NULL AND created_at < now() - interval '1 day';
  IF (SELECT count(*) FROM public.feed_images WHERE author_id = actor AND created_at > now() - interval '1 hour') >= 48
  THEN RAISE EXCEPTION 'IMAGE_LIMIT'; END IF;
  INSERT INTO public.feed_images(id, author_id, mime, content) VALUES (p_id, actor, p_mime, bytes);
  RETURN p_id;
END;
$$;

CREATE FUNCTION public.feed_read_image(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('mime', image.mime, 'data', replace(encode(image.content,'base64'), chr(10), ''))
  FROM public.feed_images image JOIN public.feed_posts post ON post.id = image.post_id
  WHERE image.id = p_id AND (post.hidden_at IS NULL OR public.is_admin(auth.uid()));
$$;

CREATE FUNCTION public.feed_save_post(p_id uuid, p_body text, p_details jsonb, p_edit boolean DEFAULT false)
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
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 24));
  IF NOT p_edit AND EXISTS (SELECT 1 FROM public.feed_posts WHERE id = p_id AND author_id = actor AND hidden_at IS NULL)
  THEN RETURN p_id; END IF;
  IF format NOT IN ('news','feedback','collaboration')
    OR (format = 'feedback' AND (title IS NULL OR attached_track IS NULL))
    OR (format = 'collaboration' AND (genre IS NULL OR requested_role IS NULL))
    OR (cue IS NOT NULL AND (cue < 0 OR format <> 'feedback'))
    OR jsonb_typeof(images) <> 'array' OR jsonb_array_length(images) > 4
  THEN RAISE EXCEPTION 'INVALID_POST_DETAILS'; END IF;
  IF attached_track IS NOT NULL AND NOT EXISTS (
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
    track_id = attached_track, cue_seconds = cue, tags = labels
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

CREATE FUNCTION public.feed_close_collaboration(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.feed_posts SET closed_at = coalesce(closed_at, now())
  WHERE id = p_id AND author_id = auth.uid() AND kind = 'collaboration' AND hidden_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.feed_delete_post(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  UPDATE public.feed_posts SET author_deleted = true, hidden_at = coalesce(hidden_at, now())
  WHERE id = p_id AND author_id = auth.uid();
END;
$$;

CREATE FUNCTION public.feed_public_post_details(p_post public.feed_posts)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'kind', p_post.kind, 'headline', p_post.headline, 'genre_id', p_post.genre_id,
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

REVOKE ALL ON FUNCTION public.feed_upload_image(uuid,text,text), public.feed_save_post(uuid,text,jsonb,boolean),
  public.feed_close_collaboration(uuid), public.feed_read_image(uuid), public.feed_public_post_details(public.feed_posts)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_upload_image(uuid,text,text), public.feed_save_post(uuid,text,jsonb,boolean),
  public.feed_close_collaboration(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.feed_read_image(uuid) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.feed_read_posts(p_stream text, p_id uuid DEFAULT NULL, p_before timestamptz DEFAULT NULL, p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(result) ORDER BY sort_at DESC, id DESC), '[]'::jsonb)
  FROM (
    SELECT post.id, post.author_id, post.body, post.created_at, public.feed_public_post_details(post) AS details,
      CASE WHEN p_stream = 'saved' THEN bookmark.created_at ELSE post.created_at END AS sort_at,
      coalesce(profile.display_name, profile.username, 'Автор') AS author_name,
      profile.avatar_url,
      bookmark.post_id IS NOT NULL AS saved,
      (SELECT count(*) FROM public.feed_post_replies reply WHERE reply.post_id = post.id) AS reply_count
    FROM public.feed_posts post
    LEFT JOIN public.profiles profile ON profile.user_id = post.author_id
    LEFT JOIN public.feed_post_bookmarks bookmark ON bookmark.post_id = post.id AND bookmark.user_id = auth.uid()
    WHERE post.hidden_at IS NULL
      AND (p_id IS NULL OR post.id = p_id)
      AND (p_id IS NOT NULL OR p_stream IN ('main', 'fresh')
        OR (p_stream = 'saved' AND bookmark.post_id IS NOT NULL)
        OR (p_stream = 'following' AND EXISTS (
          SELECT 1 FROM public.user_follows follow WHERE follow.follower_id = auth.uid() AND follow.following_id = post.author_id
        )))
      AND (p_before IS NULL OR (
        CASE WHEN p_stream = 'saved' THEN bookmark.created_at ELSE post.created_at END, post.id
      ) < (p_before, p_before_id))
    ORDER BY sort_at DESC, post.id DESC
    LIMIT 20
  ) result;
$$;
