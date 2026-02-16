-- =====================================================
-- 011-fix-admin-conversation.sql
-- Исправление RPC create_admin_conversation:
--   1) Принимает только p_target_user_id (admin = auth.uid())
--   2) Тип беседы 'admin_support' (как ожидает фронтенд)
--   3) Логика find-or-create (не создаёт дубли)
--   4) Проверка что вызывающий — админ
-- =====================================================

-- Удаляем старую версию с двумя параметрами
DROP FUNCTION IF EXISTS public.create_admin_conversation(uuid, uuid);
-- Удаляем если уже есть версия с одним параметром
DROP FUNCTION IF EXISTS public.create_admin_conversation(uuid);

CREATE OR REPLACE FUNCTION public.create_admin_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_id uuid;
  v_conversation_id uuid;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT is_admin(v_admin_id) THEN
    RAISE EXCEPTION 'Only admins can create admin conversations';
  END IF;

  -- Ищем существующий активный admin_support диалог с этим пользователем
  SELECT c.id INTO v_conversation_id
  FROM conversations c
  JOIN conversation_participants cp1 ON cp1.conversation_id = c.id AND cp1.user_id = p_target_user_id
  JOIN conversation_participants cp2 ON cp2.conversation_id = c.id AND cp2.user_id = v_admin_id
  WHERE c.type = 'admin_support'
    AND c.status != 'closed'
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;

  -- Создаём новый диалог
  INSERT INTO conversations (type, status)
  VALUES ('admin_support', 'active')
  RETURNING id INTO v_conversation_id;

  -- Добавляем участников (избегаем дубликата, если admin = target, напр. при имперсонации)
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES (v_conversation_id, v_admin_id);
  IF v_admin_id IS DISTINCT FROM p_target_user_id THEN
    INSERT INTO conversation_participants (conversation_id, user_id)
    VALUES (v_conversation_id, p_target_user_id);
  END IF;

  RETURN v_conversation_id;
END;
$$;
