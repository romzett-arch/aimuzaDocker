-- Account blocks must also stop direct-message sending at database level.

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

  IF public.is_user_blocked(p_sender_id) THEN
    RAISE EXCEPTION 'account_block_active';
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

CREATE OR REPLACE FUNCTION public.validate_direct_message_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_type text;
  v_other_user_id uuid;
BEGIN
  IF NEW.sender_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF public.is_user_blocked(NEW.sender_id) THEN
    RAISE EXCEPTION 'account_block_active';
  END IF;

  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(c.type, 'personal')
  INTO v_conversation_type
  FROM public.conversations c
  WHERE c.id = NEW.conversation_id;

  IF v_conversation_type NOT IN ('personal', 'direct') THEN
    RETURN NEW;
  END IF;

  SELECT cp.user_id
  INTO v_other_user_id
  FROM public.conversation_participants cp
  WHERE cp.conversation_id = NEW.conversation_id
    AND cp.user_id <> NEW.sender_id
  LIMIT 1;

  IF v_other_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.direct_message_blocks dmb
    WHERE (dmb.blocker_id = NEW.sender_id AND dmb.blocked_user_id = v_other_user_id)
       OR (dmb.blocker_id = v_other_user_id AND dmb.blocked_user_id = NEW.sender_id)
  ) THEN
    RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
  END IF;

  RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION public.messaging_assert_can_send(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_direct_message_permissions() TO authenticated;
