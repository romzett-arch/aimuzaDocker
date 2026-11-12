CREATE FUNCTION public.feed_notify_post_reply()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.notifications (user_id, actor_id, type, title, target_type, target_id, link)
  SELECT post.author_id, NEW.author_id, 'comment_reply', 'Новый ответ на вашу публикацию',
    'feed_post', post.id, '/feed/posts/' || post.id || '?reply=' || NEW.id
  FROM public.feed_posts post
  WHERE post.id = NEW.post_id AND post.author_id <> NEW.author_id AND post.hidden_at IS NULL;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.feed_notify_post_reply() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER feed_post_reply_notification
AFTER INSERT ON public.feed_post_replies
FOR EACH ROW EXECUTE FUNCTION public.feed_notify_post_reply();

CREATE FUNCTION public.feed_read_reply(p_post uuid, p_reply uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT to_jsonb(result)
  FROM (
    SELECT reply.id, reply.author_id, reply.body, reply.created_at,
      coalesce(profile.display_name, profile.username, 'Автор') AS author_name
    FROM public.feed_post_replies reply
    JOIN public.feed_posts post ON post.id = reply.post_id AND post.hidden_at IS NULL
    LEFT JOIN public.profiles profile ON profile.user_id = reply.author_id
    WHERE post.id = p_post AND reply.id = p_reply
  ) result;
$$;

REVOKE ALL ON FUNCTION public.feed_read_reply(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_read_reply(uuid, uuid) TO anon, authenticated;
