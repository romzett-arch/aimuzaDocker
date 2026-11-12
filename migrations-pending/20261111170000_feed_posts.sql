CREATE TABLE public.feed_posts (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  hidden_at timestamptz
);

CREATE TABLE public.feed_post_replies (
  id uuid PRIMARY KEY,
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.feed_post_bookmarks (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX feed_posts_recent ON public.feed_posts (created_at DESC, id DESC) WHERE hidden_at IS NULL;
CREATE INDEX feed_posts_author_recent ON public.feed_posts (author_id, created_at DESC);
CREATE INDEX feed_replies_post_recent ON public.feed_post_replies (post_id, created_at DESC, id DESC);
CREATE INDEX feed_replies_author_recent ON public.feed_post_replies (author_id, created_at DESC);
CREATE INDEX feed_bookmarks_post ON public.feed_post_bookmarks (post_id);

ALTER TABLE public.feed_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_post_replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_post_bookmarks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feed_posts, public.feed_post_replies, public.feed_post_bookmarks FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.feed_read_posts(p_stream text, p_id uuid DEFAULT NULL, p_before timestamptz DEFAULT NULL, p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(result) ORDER BY sort_at DESC, id DESC), '[]'::jsonb)
  FROM (
    SELECT post.id, post.author_id, post.body, post.created_at,
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

CREATE FUNCTION public.feed_read_replies(p_post uuid, p_before timestamptz DEFAULT NULL, p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(result) ORDER BY created_at DESC, id DESC), '[]'::jsonb)
  FROM (
    SELECT reply.id, reply.author_id, reply.body, reply.created_at,
      coalesce(profile.display_name, profile.username, 'Автор') AS author_name
    FROM public.feed_post_replies reply
    JOIN public.feed_posts post ON post.id = reply.post_id AND post.hidden_at IS NULL
    LEFT JOIN public.profiles profile ON profile.user_id = reply.author_id
    WHERE reply.post_id = p_post AND (p_before IS NULL OR (reply.created_at, reply.id) < (p_before, p_before_id))
    ORDER BY reply.created_at DESC, reply.id DESC LIMIT 20
  ) result;
$$;

CREATE FUNCTION public.feed_write_post(p_id uuid, p_body text, p_edit boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_body IS NULL OR char_length(btrim(p_body)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'INVALID_POST_TEXT';
  END IF;
  IF p_edit THEN
    UPDATE public.feed_posts SET body = btrim(p_body) WHERE id = p_id AND author_id = actor AND hidden_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
    RETURN p_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 24));
  IF EXISTS (SELECT 1 FROM public.feed_posts WHERE id = p_id AND author_id = actor AND hidden_at IS NULL) THEN RETURN p_id; END IF;
  IF (SELECT count(*) FROM public.feed_posts WHERE author_id = actor AND created_at >= now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'POST_LIMIT';
  END IF;
  INSERT INTO public.feed_posts (id, author_id, body) VALUES (p_id, actor, btrim(p_body));
  RETURN p_id;
END;
$$;

CREATE FUNCTION public.feed_delete_post(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  UPDATE public.feed_posts SET hidden_at = now()
    WHERE id = p_id AND author_id = auth.uid() AND hidden_at IS NULL;
END;
$$;

CREATE FUNCTION public.feed_write_reply(p_id uuid, p_post uuid, p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_body IS NULL OR char_length(btrim(p_body)) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'INVALID_REPLY_TEXT'; END IF;
  PERFORM 1 FROM public.feed_posts WHERE id = p_post AND hidden_at IS NULL FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 25));
  IF EXISTS (SELECT 1 FROM public.feed_post_replies WHERE id = p_id AND author_id = actor AND post_id = p_post) THEN RETURN p_id; END IF;
  IF (SELECT count(*) FROM public.feed_post_replies WHERE author_id = actor AND created_at >= now() - interval '1 hour') >= 40 THEN
    RAISE EXCEPTION 'REPLY_LIMIT';
  END IF;
  INSERT INTO public.feed_post_replies (id, post_id, author_id, body) VALUES (p_id, p_post, actor, btrim(p_body));
  RETURN p_id;
END;
$$;

CREATE FUNCTION public.feed_set_bookmark(p_post uuid, p_saved boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_saved THEN
    PERFORM 1 FROM public.feed_posts WHERE id = p_post AND hidden_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
    INSERT INTO public.feed_post_bookmarks (user_id, post_id) VALUES (actor, p_post) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.feed_post_bookmarks WHERE user_id = actor AND post_id = p_post;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.feed_read_posts(text, uuid, timestamptz, uuid), public.feed_read_replies(uuid, timestamptz, uuid),
  public.feed_write_post(uuid, text, boolean), public.feed_delete_post(uuid),
  public.feed_write_reply(uuid, uuid, text), public.feed_set_bookmark(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_read_posts(text, uuid, timestamptz, uuid), public.feed_read_replies(uuid, timestamptz, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_write_post(uuid, text, boolean), public.feed_delete_post(uuid),
  public.feed_write_reply(uuid, uuid, text), public.feed_set_bookmark(uuid, boolean) TO authenticated;
