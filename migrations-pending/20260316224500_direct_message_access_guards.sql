-- Персональные блокировки для личных сообщений и серверные проверки доступа.

CREATE TABLE IF NOT EXISTS public.direct_message_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_id UUID NOT NULL,
  blocked_user_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT direct_message_blocks_unique_pair UNIQUE (blocker_id, blocked_user_id),
  CONSTRAINT direct_message_blocks_no_self_block CHECK (blocker_id <> blocked_user_id)
);

CREATE INDEX IF NOT EXISTS idx_direct_message_blocks_blocker
  ON public.direct_message_blocks (blocker_id);

CREATE INDEX IF NOT EXISTS idx_direct_message_blocks_blocked
  ON public.direct_message_blocks (blocked_user_id);

ALTER TABLE public.direct_message_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own direct message blocks" ON public.direct_message_blocks;
CREATE POLICY "Users can view own direct message blocks"
ON public.direct_message_blocks
FOR SELECT
TO authenticated
USING (blocker_id = auth.uid() OR blocked_user_id = auth.uid());

DROP POLICY IF EXISTS "Users can create own direct message blocks" ON public.direct_message_blocks;
CREATE POLICY "Users can create own direct message blocks"
ON public.direct_message_blocks
FOR INSERT
TO authenticated
WITH CHECK (blocker_id = auth.uid() AND blocker_id <> blocked_user_id);

DROP POLICY IF EXISTS "Users can delete own direct message blocks" ON public.direct_message_blocks;
CREATE POLICY "Users can delete own direct message blocks"
ON public.direct_message_blocks
FOR DELETE
TO authenticated
USING (blocker_id = auth.uid());

CREATE OR REPLACE FUNCTION public.can_message_user(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND auth.uid() <> _target_user_id
    AND (
      public.is_super_admin(auth.uid())
      OR (public.is_admin(auth.uid()) AND public.is_super_admin(_target_user_id))
      OR NOT public.is_super_admin(_target_user_id)
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_message_blocks dmb
      WHERE (dmb.blocker_id = auth.uid() AND dmb.blocked_user_id = _target_user_id)
         OR (dmb.blocker_id = _target_user_id AND dmb.blocked_user_id = auth.uid())
    );
$$;

CREATE OR REPLACE FUNCTION public.get_direct_message_state(_target_user_id UUID)
RETURNS TABLE (
  has_blocked BOOLEAN,
  blocked_by_target BOOLEAN,
  can_message BOOLEAN
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
        AND dmb.blocked_user_id = _target_user_id
    ) AS has_blocked,
    EXISTS (
      SELECT 1
      FROM public.direct_message_blocks dmb
      WHERE dmb.blocker_id = _target_user_id
        AND dmb.blocked_user_id = auth.uid()
    ) AS blocked_by_target,
    public.can_message_user(_target_user_id) AS can_message;
$$;

CREATE OR REPLACE FUNCTION public.block_user_in_messages(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF auth.uid() = _target_user_id THEN
    RAISE EXCEPTION 'Нельзя заблокировать себя';
  END IF;

  IF public.is_super_admin(_target_user_id)
    AND NOT public.is_admin(auth.uid())
    AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Нельзя блокировать технического администратора';
  END IF;

  INSERT INTO public.direct_message_blocks (blocker_id, blocked_user_id)
  VALUES (auth.uid(), _target_user_id)
  ON CONFLICT (blocker_id, blocked_user_id) DO NOTHING;

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.unblock_user_in_messages(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  DELETE FROM public.direct_message_blocks
  WHERE blocker_id = auth.uid()
    AND blocked_user_id = _target_user_id;

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_direct_message_permissions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_type TEXT;
  v_other_user_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT c.type
  INTO v_conversation_type
  FROM public.conversations c
  WHERE c.id = NEW.conversation_id;

  IF COALESCE(v_conversation_type, 'personal') <> 'personal' THEN
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

  IF NOT public.can_message_user(v_other_user_id) THEN
    RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_direct_message_permissions_trigger ON public.messages;
CREATE TRIGGER validate_direct_message_permissions_trigger
  BEFORE INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_direct_message_permissions();

CREATE OR REPLACE FUNCTION public.create_conversation_with_user(p_other_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_conversation_id UUID;
  v_current_user_id UUID;
BEGIN
  v_current_user_id := auth.uid();

  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_current_user_id = p_other_user_id THEN
    RAISE EXCEPTION 'Cannot create conversation with yourself';
  END IF;

  IF NOT public.can_message_user(p_other_user_id) THEN
    RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
  END IF;

  SELECT cp1.conversation_id INTO v_conversation_id
  FROM public.conversation_participants cp1
  JOIN public.conversation_participants cp2 ON cp1.conversation_id = cp2.conversation_id
  WHERE cp1.user_id = v_current_user_id
    AND cp2.user_id = p_other_user_id
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;

  INSERT INTO public.conversations DEFAULT VALUES
  RETURNING id INTO v_conversation_id;

  INSERT INTO public.conversation_participants (conversation_id, user_id)
  VALUES
    (v_conversation_id, v_current_user_id),
    (v_conversation_id, p_other_user_id);

  RETURN v_conversation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.block_user_in_messages(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unblock_user_in_messages(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_direct_message_state(UUID) TO authenticated;
