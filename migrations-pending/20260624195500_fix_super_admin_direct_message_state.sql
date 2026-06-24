-- Keep direct-message availability on the new messaging permission path.

CREATE OR REPLACE FUNCTION public.messaging_get_direct_message_state(p_target_user_id uuid)
RETURNS TABLE (
  has_blocked boolean,
  blocked_by_target boolean,
  can_message boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.direct_message_blocks dmb
      WHERE dmb.blocker_id = auth.uid()
        AND dmb.blocked_user_id = p_target_user_id
    ) AS has_blocked,
    EXISTS (
      SELECT 1
      FROM public.direct_message_blocks dmb
      WHERE dmb.blocker_id = p_target_user_id
        AND dmb.blocked_user_id = auth.uid()
    ) AS blocked_by_target,
    public.messaging_can_user_message_target(auth.uid(), p_target_user_id) AS can_message;
$$;

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
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    UPDATE public.conversation_participants
    SET deleted_at = NULL, archived_at = NULL
    WHERE conversation_id = v_conversation_id
      AND user_id = v_current_user_id;

    RETURN v_conversation_id;
  END IF;

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

-- Compatibility names stay available inside the database, but delegate to the new policy.
CREATE OR REPLACE FUNCTION public.can_message_user(_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.messaging_can_user_message_target(auth.uid(), _target_user_id);
$$;

CREATE OR REPLACE FUNCTION public.get_direct_message_state(_target_user_id uuid)
RETURNS TABLE (
  has_blocked boolean,
  blocked_by_target boolean,
  can_message boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.messaging_get_direct_message_state(_target_user_id);
$$;

GRANT EXECUTE ON FUNCTION public.messaging_get_direct_message_state(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_create_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_message_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_direct_message_state(uuid) TO authenticated;
