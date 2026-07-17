-- Protect two legacy user-action RPCs that are executed through the owner-level
-- Node API connection.

CREATE OR REPLACE FUNCTION public.forum_mark_read(
  p_user_id uuid,
  p_entity_type text,
  p_entity_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF p_user_id <> v_actor THEN RAISE EXCEPTION 'Нельзя отмечать контент от имени другого пользователя'; END IF;
  IF p_entity_type NOT IN ('category', 'topic') THEN RAISE EXCEPTION 'Некорректный тип контента'; END IF;
  IF p_entity_type = 'category' AND NOT EXISTS (SELECT 1 FROM public.forum_categories WHERE id = p_entity_id) THEN RAISE EXCEPTION 'Категория не найдена'; END IF;
  IF p_entity_type = 'topic' AND NOT EXISTS (SELECT 1 FROM public.forum_topics WHERE id = p_entity_id AND NOT is_hidden) THEN RAISE EXCEPTION 'Тема не найдена'; END IF;

  INSERT INTO public.forum_user_reads(user_id, entity_type, entity_id, last_read_at)
  VALUES(v_actor, p_entity_type, p_entity_id, now())
  ON CONFLICT(user_id, entity_type, entity_id) DO UPDATE SET last_read_at = excluded.last_read_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_topic_author uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  SELECT user_id INTO v_topic_author FROM public.forum_topics WHERE id = p_topic_id FOR UPDATE;
  IF v_topic_author IS NULL THEN RAISE EXCEPTION 'Тема не найдена'; END IF;
  IF v_actor <> v_topic_author AND NOT (
    public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin') OR public.has_role(v_actor, 'moderator')
  ) THEN RAISE EXCEPTION 'Только автор темы или модератор может выбрать решение'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.forum_posts WHERE id = p_post_id AND topic_id = p_topic_id AND NOT is_hidden) THEN
    RAISE EXCEPTION 'Ответ не найден в этой теме';
  END IF;

  UPDATE public.forum_posts SET is_solution = false WHERE topic_id = p_topic_id AND is_solution AND id <> p_post_id;
  UPDATE public.forum_posts SET is_solution = true WHERE id = p_post_id;
  UPDATE public.forum_topics SET is_solved = true, updated_at = now() WHERE id = p_topic_id;
END;
$$;

REVOKE ALL ON FUNCTION public.forum_mark_read(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_mark_read(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_mark_read(uuid, text, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.forum_mark_solution(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_mark_solution(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_mark_solution(uuid, uuid) TO authenticated;
