-- Make messaging_send_message tolerate non-array attachment payloads from clients.

CREATE OR REPLACE FUNCTION public.messaging_send_message(
  p_conversation_id uuid,
  p_content text,
  p_attachment_url text DEFAULT NULL::text,
  p_attachment_type text DEFAULT NULL::text,
  p_forwarded_from_id uuid DEFAULT NULL::uuid,
  p_reply_to_id uuid DEFAULT NULL::uuid,
  p_sender_id uuid DEFAULT NULL::uuid,
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
  v_attachments jsonb;
  v_attachment_path text;
BEGIN
  v_sender_id := COALESCE(p_sender_id, auth.uid());
  v_attachments := CASE jsonb_typeof(p_attachments)
    WHEN 'array' THEN p_attachments
    WHEN 'object' THEN jsonb_build_array(p_attachments)
    ELSE '[]'::jsonb
  END;

  IF auth.uid() IS NOT NULL
     AND v_sender_id <> auth.uid()
     AND NOT public.is_admin(auth.uid())
     AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Cannot send message as another user';
  END IF;

  PERFORM public.messaging_assert_can_send(p_conversation_id, v_sender_id);

  IF COALESCE(trim(p_content), '') = ''
     AND p_attachment_url IS NULL
     AND jsonb_array_length(v_attachments) = 0 THEN
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
    COALESCE(NULLIF(trim(p_content), ''), CASE WHEN p_attachment_url IS NOT NULL OR jsonb_array_length(v_attachments) > 0 THEN '📎' ELSE '' END),
    p_attachment_url,
    p_attachment_type,
    p_forwarded_from_id,
    p_reply_to_id,
    CASE WHEN p_attachment_url IS NOT NULL OR jsonb_array_length(v_attachments) > 0 THEN 'attachment' ELSE 'text' END
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

  FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_attachments)
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

GRANT EXECUTE ON FUNCTION public.messaging_send_message(uuid, text, text, text, uuid, uuid, uuid, jsonb) TO authenticated;
