-- Keep the legacy messages insert trigger aligned with the messaging_* RPC rules.

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

GRANT EXECUTE ON FUNCTION public.validate_direct_message_permissions() TO authenticated;
