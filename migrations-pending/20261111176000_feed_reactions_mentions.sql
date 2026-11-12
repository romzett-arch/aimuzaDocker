CREATE TABLE public.feed_post_likes (
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  PRIMARY KEY (post_id, user_id)
);
CREATE TABLE public.feed_mentions (
  post_id uuid NOT NULL REFERENCES public.feed_posts(id) ON DELETE CASCADE,
  source_id uuid NOT NULL,
  recipient_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  handle text NOT NULL,
  PRIMARY KEY (post_id, source_id, recipient_id)
);
ALTER TABLE public.feed_post_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_mentions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feed_post_likes, public.feed_mentions FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.feed_set_post_like(p_post uuid, p_liked boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_liked IS NULL THEN RAISE EXCEPTION 'INVALID_REACTION'; END IF;
  PERFORM 1 FROM public.feed_posts
  WHERE id = p_post AND hidden_at IS NULL AND public.feed_stream_author_visible(author_id) FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POST_UNAVAILABLE'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text || ':' || p_post::text, 28));
  IF p_liked THEN
    INSERT INTO public.feed_post_likes(post_id, user_id) VALUES (p_post, actor) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.feed_post_likes WHERE post_id = p_post AND user_id = actor;
  END IF;
  RETURN public.feed_post_reaction(p_post);
END;
$$;

CREATE FUNCTION public.feed_post_reaction(p_post uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('count', count(*), 'liked', coalesce(bool_or(user_id = auth.uid()), false))
  FROM public.feed_post_likes WHERE post_id = p_post;
$$;

CREATE FUNCTION public.feed_mention_links(p_post uuid, p_source uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(jsonb_object_agg(handle, recipient_id), '{}'::jsonb)
  FROM public.feed_mentions WHERE post_id = p_post AND source_id = p_source;
$$;

CREATE FUNCTION public.feed_notify_mentions()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  post_id uuid;
  post_author uuid;
  is_reply boolean := TG_TABLE_NAME = 'feed_post_replies';
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.body IS NOT DISTINCT FROM NEW.body THEN RETURN NEW; END IF;
  post_id := CASE WHEN is_reply THEN (to_jsonb(NEW)->>'post_id')::uuid ELSE NEW.id END;
  SELECT author_id INTO post_author FROM public.feed_posts WHERE id = post_id AND hidden_at IS NULL;
  IF NOT FOUND THEN RETURN NEW; END IF;

  WITH handles AS (
    SELECT lower(match[1]) AS handle
    FROM regexp_matches(NEW.body, '(?<![[:alnum:]_.+@-])@([[:alnum:]_](?:[[:alnum:]_.-]{0,62}[[:alnum:]_])?)(?![[:alnum:]_])', 'g') WITH ORDINALITY AS matches(match, position)
    GROUP BY lower(match[1]) ORDER BY min(position) LIMIT 10
  ), recipients AS (
    SELECT handles.handle, (array_agg(profile.user_id))[1] AS recipient_id
    FROM handles JOIN public.profiles profile ON lower(profile.username) = handles.handle
    GROUP BY handles.handle HAVING count(*) = 1
  ), inserted AS (
    INSERT INTO public.feed_mentions(post_id, source_id, recipient_id, handle)
    SELECT post_id, NEW.id, r.recipient_id, r.handle FROM recipients r
    ON CONFLICT DO NOTHING RETURNING recipient_id
  )
  INSERT INTO public.notifications(user_id, actor_id, type, title, target_type, target_id, link)
  SELECT inserted.recipient_id, NEW.author_id, 'feed_mention', 'Вас упомянули в ленте',
    'feed_post', post_id, '/feed/posts/' || post_id || CASE WHEN is_reply THEN '?reply=' || NEW.id ELSE '' END
  FROM inserted WHERE inserted.recipient_id <> NEW.author_id
    AND (NOT is_reply OR inserted.recipient_id <> post_author)
    AND NOT EXISTS (
      SELECT 1 FROM public.direct_message_blocks b
      WHERE (b.blocker_id = inserted.recipient_id AND b.blocked_user_id IN (NEW.author_id, post_author))
         OR (b.blocked_user_id = inserted.recipient_id AND b.blocker_id IN (NEW.author_id, post_author))
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.feed_feedback f WHERE f.user_id = inserted.recipient_id
        AND f.feedback_type = 'hide_author' AND f.author_id IN (NEW.author_id, post_author)
    );
  RETURN NEW;
END;
$$;

CREATE INDEX feed_mention_profile_username ON public.profiles (lower(username)) WHERE username IS NOT NULL;
CREATE TRIGGER feed_post_mentions AFTER INSERT OR UPDATE OF body ON public.feed_posts
  FOR EACH ROW EXECUTE FUNCTION public.feed_notify_mentions();
CREATE TRIGGER feed_reply_mentions AFTER INSERT ON public.feed_post_replies
  FOR EACH ROW EXECUTE FUNCTION public.feed_notify_mentions();

REVOKE ALL ON FUNCTION public.feed_post_reaction(uuid), public.feed_mention_links(uuid,uuid),
  public.feed_notify_mentions(), public.feed_set_post_like(uuid,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_set_post_like(uuid,boolean) TO authenticated;


CREATE OR REPLACE FUNCTION public.feed_stream_preview(p_type text, p_id uuid, p_reason text, p_stream text, p_genre uuid)
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
      'details', public.feed_public_post_details(p), 'reaction', public.feed_post_reaction(p.id), 'mentions', public.feed_mention_links(p.id, p.id)
    ), p.kind, p.author_id INTO preview, format, author
    FROM public.feed_posts p LEFT JOIN public.profiles profile ON profile.user_id = p.author_id
    LEFT JOIN public.feed_post_bookmarks bookmark ON bookmark.post_id = p.id AND bookmark.user_id = auth.uid()
    LEFT JOIN public.tracks attachment ON attachment.id = p.track_id AND public.feed_track_visible(attachment)
    WHERE p.id = p_id AND p.hidden_at IS NULL AND public.feed_stream_author_visible(p.author_id)
      AND (p_stream <> 'main' OR p.kind <> 'collaboration' OR p.closed_at IS NULL)
      AND (p_genre IS NULL OR p.genre_id = p_genre OR attachment.genre_id = p_genre)
      AND (p_stream <> 'saved' OR bookmark.post_id IS NOT NULL);
    actions := ARRAY['open','share'];
    IF auth.uid() IS NOT NULL THEN
      actions := actions || ARRAY['reply','save','like'] || CASE WHEN auth.uid() = author THEN ARRAY['edit','delete'] ELSE ARRAY['follow','report'] END;
    END IF;
  WHEN 'forum' THEN
    SELECT jsonb_build_object('id', topic.id, 'title', topic.title, 'category', category.name_ru,
      'reply_count', greatest(coalesce(topic.posts_count, 1) - 1, 0),
      'last_post_at', topic.last_post_at, 'created_at', topic.created_at), topic.user_id INTO preview, author
    FROM public.forum_topics topic JOIN public.forum_categories category ON category.id = topic.category_id
    WHERE topic.id = p_id AND public.feed_topic_visible(topic, category) AND public.feed_stream_author_visible(topic.user_id);
    format := 'forum';
    actions := ARRAY['open','share'];
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

CREATE OR REPLACE FUNCTION public.feed_read_posts(p_stream text, p_id uuid DEFAULT NULL, p_before timestamptz DEFAULT NULL, p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(result) ORDER BY sort_at DESC, id DESC), '[]'::jsonb)
  FROM (
    SELECT post.id, post.author_id, post.body, post.created_at, public.feed_public_post_details(post) AS details, public.feed_post_reaction(post.id) AS reaction, public.feed_mention_links(post.id,post.id) AS mentions,
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

CREATE OR REPLACE FUNCTION public.feed_read_replies(p_post uuid, p_before timestamptz DEFAULT NULL, p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(result) ORDER BY created_at DESC, id DESC), '[]'::jsonb)
  FROM (
    SELECT reply.id, reply.author_id, reply.body, reply.created_at, public.feed_mention_links(post.id,reply.id) AS mentions,
      coalesce(profile.display_name, profile.username, 'Автор') AS author_name
    FROM public.feed_post_replies reply
    JOIN public.feed_posts post ON post.id = reply.post_id AND post.hidden_at IS NULL
    LEFT JOIN public.profiles profile ON profile.user_id = reply.author_id
    WHERE reply.post_id = p_post AND (p_before IS NULL OR (reply.created_at, reply.id) < (p_before, p_before_id))
    ORDER BY reply.created_at DESC, reply.id DESC LIMIT 20
  ) result;
$$;

CREATE OR REPLACE FUNCTION public.feed_read_reply(p_post uuid, p_reply uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT to_jsonb(result)
  FROM (
    SELECT reply.id, reply.author_id, reply.body, reply.created_at, public.feed_mention_links(post.id,reply.id) AS mentions,
      coalesce(profile.display_name, profile.username, 'Автор') AS author_name
    FROM public.feed_post_replies reply
    JOIN public.feed_posts post ON post.id = reply.post_id AND post.hidden_at IS NULL
    LEFT JOIN public.profiles profile ON profile.user_id = reply.author_id
    WHERE post.id = p_post AND reply.id = p_reply
  ) result;
$$;
