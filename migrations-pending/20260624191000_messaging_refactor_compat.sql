-- Messaging refactor compatibility layer.
-- Adds the new messaging_* RPC namespace while keeping legacy data shape intact.

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS last_message_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_message_at timestamptz;

ALTER TABLE public.conversation_participants
  ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'member',
  ADD COLUMN IF NOT EXISTS last_read_message_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS muted_until timestamptz,
  ADD COLUMN IF NOT EXISTS last_visible_message_id uuid REFERENCES public.messages(id) ON DELETE SET NULL;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS type text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES auth.users(id);

CREATE TABLE IF NOT EXISTS public.message_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  storage_bucket text NOT NULL DEFAULT 'message-attachments',
  storage_path text NOT NULL,
  original_name text,
  mime_type text,
  size_bytes bigint,
  kind text NOT NULL DEFAULT 'file',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_conversation_participants_user_visible_last_message
  ON public.conversation_participants (user_id, deleted_at, last_message_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_conversations_last_message_at
  ON public.conversations (last_message_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_message_attachments_message_id
  ON public.message_attachments (message_id);

CREATE INDEX IF NOT EXISTS idx_messages_reply_to_id
  ON public.messages (reply_to_id);

ALTER TABLE public.message_attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Participants can view message attachments" ON public.message_attachments;
CREATE POLICY "Participants can view message attachments"
ON public.message_attachments
FOR SELECT
TO authenticated
USING (
  public.is_admin(auth.uid())
  OR EXISTS (
    SELECT 1
    FROM public.messages m
    WHERE m.id = message_attachments.message_id
      AND public.is_participant_in_conversation(auth.uid(), m.conversation_id)
  )
);

DROP POLICY IF EXISTS "Participants can create message attachments" ON public.message_attachments;
CREATE POLICY "Participants can create message attachments"
ON public.message_attachments
FOR INSERT
TO authenticated
WITH CHECK (
  created_by = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.messages m
    WHERE m.id = message_attachments.message_id
      AND public.is_participant_in_conversation(auth.uid(), m.conversation_id)
  )
);

DROP POLICY IF EXISTS "Attachment owners can delete own message attachments" ON public.message_attachments;
CREATE POLICY "Attachment owners can delete own message attachments"
ON public.message_attachments
FOR DELETE
TO authenticated
USING (created_by = auth.uid() OR public.is_admin(auth.uid()));

WITH latest_messages AS (
  SELECT DISTINCT ON (m.conversation_id)
    m.conversation_id,
    m.id,
    m.created_at
  FROM public.messages m
  WHERE COALESCE(m.deleted_at, 'infinity'::timestamptz) > now()
  ORDER BY m.conversation_id, m.created_at DESC, m.id DESC
)
UPDATE public.conversations c
SET
  last_message_id = lm.id,
  last_message_at = lm.created_at,
  updated_at = GREATEST(COALESCE(c.updated_at, lm.created_at), lm.created_at)
FROM latest_messages lm
WHERE c.id = lm.conversation_id
  AND (
    c.last_message_id IS DISTINCT FROM lm.id
    OR c.last_message_at IS DISTINCT FROM lm.created_at
  );

UPDATE public.conversation_participants cp
SET
  last_message_id = COALESCE(cp.last_message_id, c.last_message_id),
  last_message_at = COALESCE(cp.last_message_at, c.last_message_at)
FROM public.conversations c
WHERE c.id = cp.conversation_id
  AND (
    cp.last_message_id IS NULL
    OR cp.last_message_at IS NULL
  );

INSERT INTO public.message_attachments (
  message_id,
  created_by,
  storage_bucket,
  storage_path,
  original_name,
  kind,
  created_at
)
SELECT
  m.id,
  m.sender_id,
  'message-attachments',
  regexp_replace(m.attachment_url, '^.*/storage/v1/object/public/message-attachments/', ''),
  NULLIF(split_part(m.attachment_url, '/', array_length(string_to_array(m.attachment_url, '/'), 1)), ''),
  COALESCE(NULLIF(m.attachment_type, ''), 'file'),
  m.created_at
FROM public.messages m
WHERE m.attachment_url IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.message_attachments ma
    WHERE ma.message_id = m.id
      AND ma.storage_path = regexp_replace(m.attachment_url, '^.*/storage/v1/object/public/message-attachments/', '')
  );

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
       AND NOT public.can_message_user(v_other_user_id) THEN
      RAISE EXCEPTION 'Пользователь недоступен для личных сообщений';
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_touch_conversation_on_message_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.conversations
  SET
    updated_at = GREATEST(COALESCE(updated_at, NEW.created_at), NEW.created_at),
    last_message_id = NEW.id,
    last_message_at = NEW.created_at
  WHERE id = NEW.conversation_id;

  UPDATE public.conversation_participants
  SET
    last_message_at = NEW.created_at,
    last_message_id = NEW.id,
    deleted_at = NULL,
    archived_at = NULL
  WHERE conversation_id = NEW.conversation_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_conversation_participants_on_message_insert ON public.messages;
DROP TRIGGER IF EXISTS trg_messaging_touch_conversation_on_message_insert ON public.messages;
CREATE TRIGGER trg_messaging_touch_conversation_on_message_insert
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.messaging_touch_conversation_on_message_insert();

CREATE OR REPLACE FUNCTION public.messaging_get_conversations(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  type text,
  status text,
  closed_at timestamptz,
  closed_by uuid,
  participants jsonb,
  last_message_content text,
  last_message_created_at timestamptz,
  last_message_sender_id uuid,
  last_message_attachment_url text,
  last_message_attachment_type text,
  unread_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH allowed AS (
    SELECT
      p_user_id IS NOT NULL
      AND (
        auth.uid() = p_user_id
        OR public.is_admin(auth.uid())
        OR public.is_super_admin(auth.uid())
      ) AS ok
  ),
  base AS (
    SELECT
      c.id,
      c.created_at,
      c.updated_at,
      c.type,
      c.status,
      c.closed_at,
      c.closed_by,
      self_part.last_read_at,
      self_part.last_read_message_id,
      COALESCE(self_part.last_message_at, c.last_message_at) AS last_message_at,
      COALESCE(self_part.last_message_id, c.last_message_id) AS last_message_id
    FROM public.conversation_participants self_part
    JOIN public.conversations c ON c.id = self_part.conversation_id
    JOIN allowed a ON a.ok
    WHERE self_part.user_id = p_user_id
      AND self_part.deleted_at IS NULL
  )
  SELECT
    b.id,
    b.created_at,
    COALESCE(b.last_message_at, b.updated_at, b.created_at) AS updated_at,
    COALESCE(b.type, 'personal') AS type,
    COALESCE(b.status, 'active') AS status,
    b.closed_at,
    b.closed_by,
    COALESCE(participants.participants, '[]'::jsonb) AS participants,
    lm.content AS last_message_content,
    lm.created_at AS last_message_created_at,
    lm.sender_id AS last_message_sender_id,
    lm.attachment_url AS last_message_attachment_url,
    lm.attachment_type AS last_message_attachment_type,
    COALESCE(unread.unread_count, 0)::integer AS unread_count
  FROM base b
  LEFT JOIN public.messages lm ON lm.id = b.last_message_id
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', cp.user_id,
        'profile', jsonb_build_object(
          'username', p.username,
          'avatar_url', p.avatar_url
        )
      )
      ORDER BY cp.created_at, cp.user_id
    ) AS participants
    FROM public.conversation_participants cp
    LEFT JOIN public.profiles p ON p.user_id = cp.user_id
    WHERE cp.conversation_id = b.id
  ) participants ON true
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS unread_count
    FROM public.messages m
    WHERE m.conversation_id = b.id
      AND m.sender_id <> p_user_id
      AND m.deleted_at IS NULL
      AND (
        (b.last_read_message_id IS NOT NULL AND m.created_at > COALESCE((SELECT rm.created_at FROM public.messages rm WHERE rm.id = b.last_read_message_id), '-infinity'::timestamptz))
        OR (b.last_read_message_id IS NULL AND (b.last_read_at IS NULL OR m.created_at > b.last_read_at))
      )
  ) unread ON true
  ORDER BY COALESCE(b.last_message_at, b.updated_at, b.created_at) DESC, b.id DESC;
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
  FROM public.messages m
  JOIN allowed a ON a.ok
  LEFT JOIN public.profiles p ON p.user_id = m.sender_id
  LEFT JOIN page_boundary pb ON true
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
  WHERE m.conversation_id = p_conversation_id
    AND m.deleted_at IS NULL
    AND (
      p_before_message_id IS NULL
      OR m.created_at < COALESCE(pb.created_at, 'infinity'::timestamptz)
    )
  ORDER BY m.created_at ASC, m.id ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
$$;

CREATE OR REPLACE FUNCTION public.messaging_send_message(
  p_conversation_id uuid,
  p_content text,
  p_attachment_url text DEFAULT NULL,
  p_attachment_type text DEFAULT NULL,
  p_forwarded_from_id uuid DEFAULT NULL,
  p_reply_to_id uuid DEFAULT NULL,
  p_sender_id uuid DEFAULT NULL,
  p_attachments jsonb DEFAULT '[]'::jsonb
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
  reply_to_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_id uuid;
  v_message public.messages%ROWTYPE;
  v_attachment jsonb;
  v_attachment_path text;
BEGIN
  v_sender_id := COALESCE(p_sender_id, auth.uid());

  IF auth.uid() IS NOT NULL
     AND v_sender_id <> auth.uid()
     AND NOT public.is_admin(auth.uid())
     AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Cannot send message as another user';
  END IF;

  PERFORM public.messaging_assert_can_send(p_conversation_id, v_sender_id);

  IF COALESCE(trim(p_content), '') = ''
     AND p_attachment_url IS NULL
     AND (p_attachments IS NULL OR jsonb_array_length(p_attachments) = 0) THEN
    RAISE EXCEPTION 'Сообщение не может быть пустым';
  END IF;

  INSERT INTO public.messages (
    conversation_id,
    sender_id,
    content,
    attachment_url,
    attachment_type,
    forwarded_from_id,
    reply_to_id,
    type
  )
  VALUES (
    p_conversation_id,
    v_sender_id,
    COALESCE(NULLIF(trim(p_content), ''), CASE WHEN p_attachment_url IS NOT NULL THEN '📎' ELSE '' END),
    p_attachment_url,
    p_attachment_type,
    p_forwarded_from_id,
    p_reply_to_id,
    CASE WHEN p_attachment_url IS NOT NULL OR jsonb_array_length(COALESCE(p_attachments, '[]'::jsonb)) > 0 THEN 'attachment' ELSE 'text' END
  )
  RETURNING * INTO v_message;

  IF p_attachment_url IS NOT NULL THEN
    v_attachment_path := regexp_replace(p_attachment_url, '^.*/storage/v1/object/public/message-attachments/', '');

    INSERT INTO public.message_attachments (
      message_id,
      created_by,
      storage_bucket,
      storage_path,
      original_name,
      kind
    )
    VALUES (
      v_message.id,
      v_sender_id,
      'message-attachments',
      v_attachment_path,
      NULLIF(split_part(v_attachment_path, '/', array_length(string_to_array(v_attachment_path, '/'), 1)), ''),
      COALESCE(NULLIF(p_attachment_type, ''), 'file')
    )
    ON CONFLICT DO NOTHING;
  END IF;

  FOR v_attachment IN SELECT * FROM jsonb_array_elements(COALESCE(p_attachments, '[]'::jsonb))
  LOOP
    INSERT INTO public.message_attachments (
      message_id,
      created_by,
      storage_bucket,
      storage_path,
      original_name,
      mime_type,
      size_bytes,
      kind
    )
    VALUES (
      v_message.id,
      v_sender_id,
      COALESCE(v_attachment->>'storage_bucket', 'message-attachments'),
      v_attachment->>'storage_path',
      v_attachment->>'original_name',
      v_attachment->>'mime_type',
      NULLIF(v_attachment->>'size_bytes', '')::bigint,
      COALESCE(v_attachment->>'kind', 'file')
    );
  END LOOP;

  RETURN QUERY
  SELECT
    v_message.id,
    v_message.conversation_id,
    v_message.sender_id,
    v_message.content,
    COALESCE(v_message.is_read, false),
    v_message.created_at,
    v_message.updated_at,
    v_message.attachment_url,
    v_message.attachment_type,
    v_message.forwarded_from_id,
    v_message.reply_to_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_mark_read(
  p_conversation_id uuid,
  p_message_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id uuid;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF auth.uid() IS NOT NULL
     AND p_user_id <> auth.uid()
     AND NOT public.is_admin(auth.uid())
     AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Cannot mark messages as another user';
  END IF;

  IF NOT public.is_participant_in_conversation(p_user_id, p_conversation_id) THEN
    RAISE EXCEPTION 'Not a participant';
  END IF;

  v_message_id := p_message_id;

  IF v_message_id IS NULL THEN
    SELECT m.id
    INTO v_message_id
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.deleted_at IS NULL
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT 1;
  END IF;

  UPDATE public.conversation_participants
  SET
    last_read_at = now(),
    last_read_message_id = COALESCE(v_message_id, last_read_message_id)
  WHERE conversation_id = p_conversation_id
    AND user_id = p_user_id;

  RETURN TRUE;
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

  UPDATE public.conversation_participants
  SET
    deleted_at = now(),
    archived_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = p_user_id;

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_get_unread_count(p_user_id uuid DEFAULT auth.uid())
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(sum(unread_count), 0)::integer
  FROM public.messaging_get_conversations(p_user_id);
$$;

CREATE OR REPLACE FUNCTION public.messaging_get_notification_payload(p_message_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  sender_id uuid,
  content text,
  conversation_type text,
  sender_name text,
  sender_avatar text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    m.id AS message_id,
    m.conversation_id,
    m.sender_id,
    m.content,
    COALESCE(c.type, 'personal') AS conversation_type,
    COALESCE(p.username, 'Пользователь') AS sender_name,
    p.avatar_url AS sender_avatar
  FROM public.messages m
  JOIN public.conversations c ON c.id = m.conversation_id
  LEFT JOIN public.profiles p ON p.user_id = m.sender_id
  WHERE p_user_id IS NOT NULL
    AND m.id = p_message_id
    AND m.deleted_at IS NULL
    AND (
      public.is_admin(auth.uid())
      OR public.is_super_admin(auth.uid())
      OR EXISTS (
        SELECT 1
        FROM public.conversation_participants cp
        WHERE cp.conversation_id = m.conversation_id
          AND cp.user_id = p_user_id
          AND cp.deleted_at IS NULL
      )
    );
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

  IF NOT public.can_message_user(p_target_user_id) THEN
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

CREATE OR REPLACE FUNCTION public.messaging_create_admin_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can create admin conversations';
  END IF;

  SELECT c.id
  INTO v_conversation_id
  FROM public.conversations c
  JOIN public.conversation_participants cp1 ON cp1.conversation_id = c.id AND cp1.user_id = auth.uid()
  JOIN public.conversation_participants cp2 ON cp2.conversation_id = c.id AND cp2.user_id = p_target_user_id
  WHERE c.type = 'admin_support'
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    UPDATE public.conversations
    SET status = 'active', closed_by = NULL, closed_at = NULL
    WHERE id = v_conversation_id
      AND status = 'closed';

    UPDATE public.conversation_participants
    SET deleted_at = NULL, archived_at = NULL
    WHERE conversation_id = v_conversation_id;

    RETURN v_conversation_id;
  END IF;

  INSERT INTO public.conversations (type, status, created_by)
  VALUES ('admin_support', 'active', auth.uid())
  RETURNING id INTO v_conversation_id;

  INSERT INTO public.conversation_participants (conversation_id, user_id, role)
  VALUES
    (v_conversation_id, auth.uid(), 'admin'),
    (v_conversation_id, p_target_user_id, 'member');

  RETURN v_conversation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.messaging_close_admin_conversation(p_conversation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can close admin conversations';
  END IF;

  UPDATE public.conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id
    AND type = 'admin_support'
    AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found or already closed';
  END IF;

  RETURN TRUE;
END;
$$;

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
  SELECT *
  FROM public.get_direct_message_state(p_target_user_id);
$$;

CREATE OR REPLACE FUNCTION public.messaging_block_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.block_user_in_messages(p_target_user_id);
$$;

CREATE OR REPLACE FUNCTION public.messaging_unblock_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.unblock_user_in_messages(p_target_user_id);
$$;

-- Compatibility wrappers for legacy RPC names.
CREATE OR REPLACE FUNCTION public.create_conversation_with_user(p_other_user_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.messaging_create_direct_conversation(p_other_user_id);
$$;

CREATE OR REPLACE FUNCTION public.create_admin_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.messaging_create_admin_conversation(p_target_user_id);
$$;

CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.messaging_close_admin_conversation(p_conversation_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_conversations(p_user_id uuid)
RETURNS TABLE (
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  type text,
  status text,
  closed_at timestamptz,
  closed_by uuid,
  participants jsonb,
  last_message_content text,
  last_message_created_at timestamptz,
  last_message_sender_id uuid,
  unread_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    c.id,
    c.created_at,
    c.updated_at,
    c.type,
    c.status,
    c.closed_at,
    c.closed_by,
    c.participants,
    c.last_message_content,
    c.last_message_created_at,
    c.last_message_sender_id,
    c.unread_count
  FROM public.messaging_get_conversations(p_user_id) c;
$$;

CREATE OR REPLACE FUNCTION public.get_user_unread_message_count(p_user_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.messaging_get_unread_count(p_user_id);
$$;

CREATE OR REPLACE FUNCTION public.get_message_notification_payload(p_message_id uuid, p_user_id uuid)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  sender_id uuid,
  content text,
  conversation_type text,
  sender_name text,
  sender_avatar text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.messaging_get_notification_payload(p_message_id, p_user_id);
$$;

GRANT EXECUTE ON FUNCTION public.messaging_create_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_create_admin_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_conversations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_messages(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_send_message(uuid, text, text, text, uuid, uuid, uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_mark_read(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_archive_conversation(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_unread_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_notification_payload(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_close_admin_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_get_direct_message_state(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_block_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.messaging_unblock_user(uuid) TO authenticated;
