-- Legacy deletes only archived one participant. Do not resurrect those conversations
-- when a user starts a new personal dialog; replace them with a clean conversation.

CREATE OR REPLACE FUNCTION public.messaging_create_direct_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
  v_current_user_id uuid;
BEGIN
  v_current_user_id := auth.uid();

  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_current_user_id = p_target_user_id THEN
    RAISE EXCEPTION 'Cannot create conversation with yourself';
  END IF;

  IF NOT public.messaging_can_user_message_target(v_current_user_id, p_target_user_id) THEN
    RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
  END IF;

  SELECT c.id
  INTO v_conversation_id
  FROM public.conversations c
  JOIN public.conversation_participants cp1 ON cp1.conversation_id = c.id
  JOIN public.conversation_participants cp2 ON cp2.conversation_id = c.id
  WHERE cp1.user_id = v_current_user_id
    AND cp2.user_id = p_target_user_id
    AND COALESCE(c.type, 'personal') IN ('personal', 'direct')
    AND cp1.deleted_at IS NULL
    AND cp1.archived_at IS NULL
    AND cp2.deleted_at IS NULL
    AND cp2.archived_at IS NULL
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;

  DELETE FROM public.conversations c
  USING public.conversation_participants cp1,
        public.conversation_participants cp2
  WHERE cp1.conversation_id = c.id
    AND cp2.conversation_id = c.id
    AND cp1.user_id = v_current_user_id
    AND cp2.user_id = p_target_user_id
    AND COALESCE(c.type, 'personal') IN ('personal', 'direct');

  INSERT INTO public.conversations (type, status, created_by)
  VALUES ('personal', 'active', v_current_user_id)
  RETURNING id INTO v_conversation_id;

  INSERT INTO public.conversation_participants (conversation_id, user_id)
  VALUES
    (v_conversation_id, v_current_user_id),
    (v_conversation_id, p_target_user_id);

  RETURN v_conversation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.messaging_create_direct_conversation(uuid) TO authenticated;
