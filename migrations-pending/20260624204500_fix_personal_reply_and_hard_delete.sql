-- Personal messaging semantics:
-- 1. A participant can reply inside an existing personal conversation, including to super_admin.
-- 2. Deleting a personal conversation removes the conversation and its message history.

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
  WITH block_state AS (
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
      ) AS blocked_by_target
  ),
  existing_personal_conversation AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.conversations c
      JOIN public.conversation_participants cp_self
        ON cp_self.conversation_id = c.id
       AND cp_self.user_id = auth.uid()
      JOIN public.conversation_participants cp_target
        ON cp_target.conversation_id = c.id
       AND cp_target.user_id = p_target_user_id
      WHERE COALESCE(c.type, 'personal') IN ('personal', 'direct')
    ) AS exists
  )
  SELECT
    bs.has_blocked,
    bs.blocked_by_target,
    NOT bs.has_blocked
      AND NOT bs.blocked_by_target
      AND (
        public.messaging_can_user_message_target(auth.uid(), p_target_user_id)
        OR epc.exists
      ) AS can_message
  FROM block_state bs
  CROSS JOIN existing_personal_conversation epc;
$$;

CREATE OR REPLACE FUNCTION public.messaging_assert_can_send(
  p_conversation_id uuid,
  p_sender_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_type text;
  v_status text;
  v_other_user_id uuid;
BEGIN
  IF p_sender_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT COALESCE(c.type, 'personal'), COALESCE(c.status, 'active')
  INTO v_conversation_type, v_status
  FROM public.conversations c
  WHERE c.id = p_conversation_id;

  IF v_conversation_type IS NULL THEN
    RAISE EXCEPTION 'Диалог не найден';
  END IF;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Диалог завершён администратором';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversation_participants cp
    WHERE cp.conversation_id = p_conversation_id
      AND cp.user_id = p_sender_id
  ) THEN
    RAISE EXCEPTION 'Пользователь не является участником диалога';
  END IF;

  IF v_conversation_type IN ('personal', 'direct') THEN
    SELECT cp.user_id
    INTO v_other_user_id
    FROM public.conversation_participants cp
    WHERE cp.conversation_id = p_conversation_id
      AND cp.user_id <> p_sender_id
    LIMIT 1;

    IF v_other_user_id IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM public.direct_message_blocks dmb
         WHERE (dmb.blocker_id = p_sender_id AND dmb.blocked_user_id = v_other_user_id)
            OR (dmb.blocker_id = v_other_user_id AND dmb.blocked_user_id = p_sender_id)
       ) THEN
      RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_archive_conversation(
  p_conversation_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_type text;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF auth.uid() IS NOT NULL
     AND p_user_id <> auth.uid()
     AND NOT public.is_admin(auth.uid())
     AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Cannot archive conversation as another user';
  END IF;

  IF NOT public.is_participant_in_conversation(p_user_id, p_conversation_id) THEN
    RAISE EXCEPTION 'Not a participant';
  END IF;

  SELECT COALESCE(type, 'personal')
  INTO v_conversation_type
  FROM public.conversations
  WHERE id = p_conversation_id;

  IF v_conversation_type IN ('personal', 'direct') THEN
    DELETE FROM public.conversations
    WHERE id = p_conversation_id;

    RETURN TRUE;
  END IF;

  UPDATE public.conversation_participants
  SET
    deleted_at = now(),
    archived_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = p_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.messaging_get_direct_message_state(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_assert_can_send(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_archive_conversation(uuid, uuid) TO authenticated;
