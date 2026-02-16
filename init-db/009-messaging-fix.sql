-- =====================================================
-- 009-messaging-fix.sql
-- Комплексное исправление системы сообщений:
--   - Добавление недостающих колонок
--   - Включение RLS на всех таблицах
--   - Создание RLS-политик
--   - Создание вспомогательных функций и RPC
--   - Добавление индексов
-- =====================================================

-- ─────────────────────────────────────────────────────
-- 1. Добавить недостающие колонки
-- ─────────────────────────────────────────────────────

-- messages: добавить conversation_id, attachment_type, forwarded_from_id, deleted_at, updated_at
ALTER TABLE public.messages 
  ADD COLUMN IF NOT EXISTS conversation_id uuid REFERENCES public.conversations(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS attachment_type text,
  ADD COLUMN IF NOT EXISTS forwarded_from_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- conversations: добавить status, closed_by, closed_at
ALTER TABLE public.conversations 
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS closed_by uuid,
  ADD COLUMN IF NOT EXISTS closed_at timestamptz;

-- ─────────────────────────────────────────────────────
-- 2. Включить RLS на всех таблицах сообщений
-- ─────────────────────────────────────────────────────

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────
-- 3. Обновить is_admin чтобы включал super_admin
-- ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_admin(_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id
      AND role IN ('admin', 'super_admin')
  )
$$;

-- ─────────────────────────────────────────────────────
-- 4. Создать вспомогательную функцию (SECURITY DEFINER для обхода RLS)
-- ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_participant_in_conversation(p_user_id uuid, p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM conversation_participants
    WHERE user_id = p_user_id AND conversation_id = p_conversation_id
  )
$$;

-- ─────────────────────────────────────────────────────
-- 5. RLS политики: conversations
-- ─────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Participants can view conversations" ON conversations;
CREATE POLICY "Participants can view conversations" ON conversations
  FOR SELECT TO authenticated
  USING (
    is_participant_in_conversation(auth.uid(), id) OR is_admin(auth.uid())
  );

DROP POLICY IF EXISTS "Functions can insert conversations" ON conversations;
CREATE POLICY "Functions can insert conversations" ON conversations
  FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Admins can update conversations" ON conversations;
CREATE POLICY "Admins can update conversations" ON conversations
  FOR UPDATE TO authenticated
  USING (is_admin(auth.uid()) OR is_participant_in_conversation(auth.uid(), id));

DROP POLICY IF EXISTS "Admins can delete conversations" ON conversations;
CREATE POLICY "Admins can delete conversations" ON conversations
  FOR DELETE TO authenticated
  USING (is_admin(auth.uid()));

-- ─────────────────────────────────────────────────────
-- 6. RLS политики: conversation_participants
-- ─────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Users can view own participations" ON conversation_participants;
CREATE POLICY "Users can view own participations" ON conversation_participants
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid() 
    OR is_admin(auth.uid()) 
    OR is_participant_in_conversation(auth.uid(), conversation_id)
  );

DROP POLICY IF EXISTS "Functions can insert participants" ON conversation_participants;
CREATE POLICY "Functions can insert participants" ON conversation_participants
  FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Users can leave conversations" ON conversation_participants;
CREATE POLICY "Users can leave conversations" ON conversation_participants
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can update own participation" ON conversation_participants;
CREATE POLICY "Users can update own participation" ON conversation_participants
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid());

-- ─────────────────────────────────────────────────────
-- 7. RLS политики: messages
-- ─────────────────────────────────────────────────────

-- Удалить все старые политики messages
DROP POLICY IF EXISTS "Users can view their own messages" ON messages;
DROP POLICY IF EXISTS "Users can send messages to their conversations" ON messages;
DROP POLICY IF EXISTS "Prevent messages in closed conversations" ON messages;
DROP POLICY IF EXISTS "Participants can view messages" ON messages;
DROP POLICY IF EXISTS "Admin can view all messages" ON messages;
DROP POLICY IF EXISTS "Participants can send messages" ON messages;
DROP POLICY IF EXISTS "Users can soft delete own messages" ON messages;
DROP POLICY IF EXISTS "Users can insert messages" ON messages;
DROP POLICY IF EXISTS "Users can update own messages" ON messages;

-- Участники видят сообщения (кроме удалённых)
CREATE POLICY "Participants can view messages" ON messages
  FOR SELECT TO authenticated
  USING (
    deleted_at IS NULL 
    AND is_participant_in_conversation(auth.uid(), conversation_id)
  );

-- Админы видят ВСЕ сообщения (включая удалённые)
CREATE POLICY "Admin can view all messages" ON messages
  FOR SELECT TO authenticated
  USING (is_admin(auth.uid()));

-- Участники могут отправлять сообщения (PERMISSIVE)
CREATE POLICY "Participants can send messages" ON messages
  FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = auth.uid()
    AND is_participant_in_conversation(auth.uid(), conversation_id)
  );

-- Блокировка в закрытых диалогах (RESTRICTIVE — все RESTRICTIVE должны пройти)
CREATE POLICY "Prevent messages in closed conversations" ON messages
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (
      SELECT 1 FROM conversations WHERE id = conversation_id AND status = 'closed'
    )
  );

-- Мягкое удаление собственных сообщений
CREATE POLICY "Users can soft delete own messages" ON messages
  FOR UPDATE TO authenticated
  USING (sender_id = auth.uid())
  WITH CHECK (sender_id = auth.uid());

-- ─────────────────────────────────────────────────────
-- 8. RLS политики: message_reactions
-- ─────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Participants can view reactions" ON message_reactions;
DROP POLICY IF EXISTS "Participants can add reactions" ON message_reactions;
DROP POLICY IF EXISTS "Users can remove own reactions" ON message_reactions;
DROP POLICY IF EXISTS "Users can manage own reactions" ON message_reactions;

CREATE POLICY "Participants can view reactions" ON message_reactions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM messages m
      WHERE m.id = message_reactions.message_id
      AND is_participant_in_conversation(auth.uid(), m.conversation_id)
    )
    OR is_admin(auth.uid())
  );

CREATE POLICY "Participants can add reactions" ON message_reactions
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM messages m
      WHERE m.id = message_reactions.message_id
      AND is_participant_in_conversation(auth.uid(), m.conversation_id)
    )
  );

CREATE POLICY "Users can remove own reactions" ON message_reactions
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ─────────────────────────────────────────────────────
-- 9. Индексы
-- ─────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_conv_participants_user_id ON conversation_participants(user_id);
CREATE INDEX IF NOT EXISTS idx_messages_forwarded_from_id ON messages(forwarded_from_id);
CREATE INDEX IF NOT EXISTS idx_message_reactions_message_id ON message_reactions(message_id);

-- ─────────────────────────────────────────────────────
-- 10. Исправить create_conversation_with_user — использовать auth.uid()
-- ─────────────────────────────────────────────────────

-- Удалить старую функцию (у неё 2 параметра)
DROP FUNCTION IF EXISTS public.create_conversation_with_user(uuid, uuid);
DROP FUNCTION IF EXISTS public.create_conversation_with_user(uuid);

CREATE FUNCTION public.create_conversation_with_user(p_other_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_conversation_id uuid;
  v_current_user_id uuid;
BEGIN
  v_current_user_id := auth.uid();
  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  
  -- Ищем существующий direct-диалог между двумя пользователями
  SELECT cp1.conversation_id INTO v_conversation_id
  FROM conversation_participants cp1
  JOIN conversation_participants cp2 ON cp1.conversation_id = cp2.conversation_id
  JOIN conversations c ON c.id = cp1.conversation_id
  WHERE cp1.user_id = v_current_user_id 
    AND cp2.user_id = p_other_user_id
    AND c.type = 'direct'
  LIMIT 1;
  
  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;
  
  -- Создаём новый диалог
  INSERT INTO conversations (type) VALUES ('direct')
  RETURNING id INTO v_conversation_id;
  
  -- Добавляем обоих участников
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES 
    (v_conversation_id, v_current_user_id),
    (v_conversation_id, p_other_user_id);
  
  RETURN v_conversation_id;
END;
$$;

-- ─────────────────────────────────────────────────────
-- 11. Функции закрытия admin-диалога
-- ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Only admins can close conversations';
  END IF;
  
  UPDATE conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found or already closed';
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────
-- 12. RPC: get_unread_counts — заменяет N+1 запросы
-- ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_unread_counts(uuid);
CREATE FUNCTION public.get_unread_counts(p_user_id uuid)
RETURNS TABLE(conversation_id uuid, unread_count bigint)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT 
    cp.conversation_id,
    COUNT(m.id) AS unread_count
  FROM conversation_participants cp
  LEFT JOIN messages m ON m.conversation_id = cp.conversation_id
    AND m.sender_id != p_user_id
    AND m.created_at > COALESCE(cp.last_read_at, '1970-01-01'::timestamptz)
    AND m.deleted_at IS NULL
  WHERE cp.user_id = p_user_id
  GROUP BY cp.conversation_id;
$$;

-- ─────────────────────────────────────────────────────
-- 13. RPC: get_last_messages — одним запросом для всех диалогов
-- ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_last_messages(uuid[]);
CREATE FUNCTION public.get_last_messages(p_conversation_ids uuid[])
RETURNS TABLE(conversation_id uuid, content text, created_at timestamptz, sender_id uuid)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT DISTINCT ON (m.conversation_id)
    m.conversation_id,
    m.content,
    m.created_at,
    m.sender_id
  FROM messages m
  WHERE m.conversation_id = ANY(p_conversation_ids)
    AND m.deleted_at IS NULL
  ORDER BY m.conversation_id, m.created_at DESC;
$$;

-- ─────────────────────────────────────────────────────
-- 14. Realtime publication
-- ─────────────────────────────────────────────────────

DO $$
BEGIN
  -- Добавляем таблицы в публикацию realtime (игнорируем если уже есть)
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.conversation_participants; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.messages; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reactions; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

-- ─────────────────────────────────────────────────────
-- 15. Notify trigger для messages (если не существует)
-- ─────────────────────────────────────────────────────

-- Функция уже должна существовать (notify_table_change)
-- Trigger уже должен быть на messages

-- Добавить trigger на conversations если нет
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_conversations'
  ) THEN
    CREATE TRIGGER trg_notify_conversations
      AFTER INSERT OR UPDATE OR DELETE ON public.conversations
      FOR EACH ROW EXECUTE FUNCTION notify_table_change();
  END IF;
END $$;
