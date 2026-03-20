-- Follow-up for databases where 20260318210000 partially applied before function fixes.

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
  WITH allowed AS (
    SELECT
      auth.uid() IS NOT NULL
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
      self_part.last_message_at,
      self_part.last_message_id
    FROM public.conversation_participants self_part
    JOIN public.conversations c ON c.id = self_part.conversation_id
    JOIN allowed a ON a.ok
    WHERE self_part.user_id = p_user_id
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
      AND (
        b.last_read_at IS NULL
        OR m.created_at > b.last_read_at
      )
  ) unread ON true
  ORDER BY COALESCE(b.last_message_at, b.updated_at, b.created_at) DESC, b.id DESC;
$$;

CREATE OR REPLACE FUNCTION public.get_user_unread_message_count(p_user_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH allowed AS (
    SELECT
      auth.uid() IS NOT NULL
      AND (
        auth.uid() = p_user_id
        OR public.is_admin(auth.uid())
        OR public.is_super_admin(auth.uid())
      ) AS ok
  )
  SELECT COALESCE(sum(unread_count), 0)::integer
  FROM public.get_user_conversations(p_user_id)
  WHERE (SELECT ok FROM allowed);
$$;

CREATE OR REPLACE FUNCTION public.forum_get_users_profiles(p_user_ids uuid[])
RETURNS TABLE (
  user_id uuid,
  reputation_score integer,
  trust_level integer,
  trust_label text,
  trust_color text,
  trust_icon text,
  topics_created integer,
  posts_created integer,
  likes_given integer,
  likes_received integer,
  solutions_count integer,
  warnings_count integer,
  is_silenced boolean,
  silenced_until timestamptz,
  can_downvote boolean,
  can_upload_files boolean,
  can_use_reactions boolean,
  next_level_rep integer,
  next_level_label text,
  progress_to_next integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ids AS (
    SELECT DISTINCT unnest(COALESCE(p_user_ids, ARRAY[]::uuid[])) AS user_id
  )
  SELECT
    ids.user_id,
    COALESCE(fus.reputation_score, 0) AS reputation_score,
    COALESCE(fus.trust_level, 0) AS trust_level,
    CASE COALESCE(fus.trust_level, 0)
      WHEN 4 THEN 'Модератор'
      WHEN 3 THEN 'Лидер'
      WHEN 2 THEN 'Активный'
      WHEN 1 THEN 'Участник'
      ELSE 'Новичок'
    END AS trust_label,
    CASE COALESCE(fus.trust_level, 0)
      WHEN 4 THEN '#f97316'
      WHEN 3 THEN '#a855f7'
      WHEN 2 THEN '#22c55e'
      WHEN 1 THEN '#60a5fa'
      ELSE '#888888'
    END AS trust_color,
    NULL::text AS trust_icon,
    COALESCE(fus.topics_created, 0) AS topics_created,
    COALESCE(fus.posts_created, 0) AS posts_created,
    COALESCE(fus.likes_given, 0) AS likes_given,
    COALESCE(fus.likes_received, 0) AS likes_received,
    COALESCE(fus.solutions_count, 0) AS solutions_count,
    COALESCE(fus.warnings_count, 0) AS warnings_count,
    false AS is_silenced,
    NULL::timestamptz AS silenced_until,
    COALESCE(fus.trust_level, 0) >= 2 AS can_downvote,
    COALESCE(fus.trust_level, 0) >= 1 AS can_upload_files,
    COALESCE(fus.trust_level, 0) >= 1 AS can_use_reactions,
    NULL::integer AS next_level_rep,
    NULL::text AS next_level_label,
    0 AS progress_to_next
  FROM ids
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = ids.user_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_conversations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_unread_message_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_get_users_profiles(uuid[]) TO authenticated;
