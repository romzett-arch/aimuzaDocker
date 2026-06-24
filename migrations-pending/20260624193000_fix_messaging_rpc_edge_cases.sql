-- Fix edge cases in the new messaging RPC layer:
-- 1. service-role/impersonation sends must validate p_sender_id, not auth.uid()
-- 2. message history should return the latest page sorted ascending for display

CREATE OR REPLACE FUNCTION public.messaging_can_user_message_target(
  p_sender_id uuid,
  p_target_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_sender_id IS NOT NULL
    AND p_target_user_id IS NOT NULL
    AND p_sender_id <> p_target_user_id
    AND (
      public.is_super_admin(p_sender_id)
      OR (public.is_admin(p_sender_id) AND public.is_super_admin(p_target_user_id))
      OR NOT public.is_super_admin(p_target_user_id)
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_message_blocks dmb
      WHERE (dmb.blocker_id = p_sender_id AND dmb.blocked_user_id = p_target_user_id)
         OR (dmb.blocker_id = p_target_user_id AND dmb.blocked_user_id = p_sender_id)
    );
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
       AND NOT public.messaging_can_user_message_target(p_sender_id, v_other_user_id) THEN
      RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_get_messages(
  p_conversation_id uuid,
  p_before_message_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  content text,
  is_read boolean,
  created_at timestamptz,
  updated_at timestamptz,
  attachment_url text,
  attachment_type text,
  forwarded_from_id uuid,
  reply_to_id uuid,
  deleted_at timestamptz,
  sender_profile jsonb,
  attachments jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH allowed AS (
    SELECT
      auth.uid() IS NOT NULL
      AND (
        public.is_admin(auth.uid())
        OR public.is_participant_in_conversation(auth.uid(), p_conversation_id)
      ) AS ok
  ),
  page_boundary AS (
    SELECT m.created_at
    FROM public.messages m
    WHERE m.id = p_before_message_id
  ),
  latest_page AS (
    SELECT m.*
    FROM public.messages m
    JOIN allowed a ON a.ok
    LEFT JOIN page_boundary pb ON true
    WHERE m.conversation_id = p_conversation_id
      AND m.deleted_at IS NULL
      AND (
        p_before_message_id IS NULL
        OR m.created_at < COALESCE(pb.created_at, 'infinity'::timestamptz)
      )
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200)
  )
  SELECT
    m.id,
    m.conversation_id,
    m.sender_id,
    m.content,
    COALESCE(m.is_read, false) AS is_read,
    m.created_at,
    m.updated_at,
    m.attachment_url,
    m.attachment_type,
    m.forwarded_from_id,
    m.reply_to_id,
    m.deleted_at,
    jsonb_build_object(
      'username', p.username,
      'avatar_url', p.avatar_url
    ) AS sender_profile,
    COALESCE(attachments.items, '[]'::jsonb) AS attachments
  FROM latest_page m
  LEFT JOIN public.profiles p ON p.user_id = m.sender_id
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', ma.id,
        'storage_bucket', ma.storage_bucket,
        'storage_path', ma.storage_path,
        'original_name', ma.original_name,
        'mime_type', ma.mime_type,
        'size_bytes', ma.size_bytes,
        'kind', ma.kind,
        'created_at', ma.created_at
      )
      ORDER BY ma.created_at, ma.id
    ) AS items
    FROM public.message_attachments ma
    WHERE ma.message_id = m.id
  ) attachments ON true
  ORDER BY m.created_at ASC, m.id ASC;
$$;

GRANT EXECUTE ON FUNCTION public.messaging_can_user_message_target(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_messages(uuid, uuid, integer) TO authenticated;
