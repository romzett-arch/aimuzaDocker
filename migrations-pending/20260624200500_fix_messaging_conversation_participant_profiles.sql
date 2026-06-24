-- Fix participant profile lookup in the latest conversations RPC definition.

CREATE OR REPLACE FUNCTION public.messaging_get_conversations(p_user_id uuid DEFAULT NULL)
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
SECURITY DEFINER
SET search_path = public
AS $$
  WITH current_user_id AS (
    SELECT COALESCE(p_user_id, auth.uid()) AS id
  ),
  base AS (
    SELECT c.*
    FROM public.conversations c
    JOIN public.conversation_participants cp ON cp.conversation_id = c.id
    JOIN current_user_id cu ON cu.id = cp.user_id
    WHERE cp.deleted_at IS NULL
  ),
  unread AS (
    SELECT
      b.id AS conversation_id,
      COUNT(m.id)::integer AS unread_count
    FROM base b
    JOIN current_user_id cu ON true
    JOIN public.conversation_participants cp
      ON cp.conversation_id = b.id
     AND cp.user_id = cu.id
    LEFT JOIN public.messages m
      ON m.conversation_id = b.id
     AND m.sender_id <> cu.id
     AND m.deleted_at IS NULL
     AND (
       cp.last_read_at IS NULL
       OR m.created_at > cp.last_read_at
     )
    GROUP BY b.id
  )
  SELECT
    b.id,
    b.created_at,
    b.updated_at,
    b.type,
    b.status,
    b.closed_at,
    b.closed_by,
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', cp.user_id,
          'role', cp.role,
          'profile', jsonb_build_object(
            'username', p.username,
            'avatar_url', p.avatar_url
          )
        )
        ORDER BY cp.created_at
      )
      FROM public.conversation_participants cp
      LEFT JOIN public.profiles p ON p.user_id = cp.user_id
      WHERE cp.conversation_id = b.id
        AND cp.deleted_at IS NULL
    ) AS participants,
    lm.content AS last_message_content,
    lm.created_at AS last_message_created_at,
    lm.sender_id AS last_message_sender_id,
    COALESCE(
      lm.attachment_url,
      CASE
        WHEN lma.storage_path IS NULL THEN NULL
        WHEN lma.storage_path ~ '^(https?:)?//' OR lma.storage_path LIKE '/%' THEN lma.storage_path
        ELSE '/storage/v1/object/public/' || lma.storage_bucket || '/' || lma.storage_path
      END
    ) AS last_message_attachment_url,
    COALESCE(lm.attachment_type, lma.kind) AS last_message_attachment_type,
    COALESCE(unread.unread_count, 0)::integer AS unread_count
  FROM base b
  LEFT JOIN public.messages lm ON lm.id = b.last_message_id
  LEFT JOIN LATERAL (
    SELECT ma.storage_bucket, ma.storage_path, ma.kind
    FROM public.message_attachments ma
    WHERE ma.message_id = lm.id
    ORDER BY ma.created_at, ma.id
    LIMIT 1
  ) lma ON true
  LEFT JOIN unread ON unread.conversation_id = b.id
  ORDER BY COALESCE(b.last_message_at, b.updated_at, b.created_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.messaging_get_conversations(uuid) TO authenticated;
