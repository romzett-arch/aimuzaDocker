-- Reduce client-side polling and N+1 load for messaging, sidebar, QA, comments, and forum badges.

ALTER TABLE public.conversation_participants
  ADD COLUMN IF NOT EXISTS last_message_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_message_id uuid REFERENCES public.messages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_conversation_participants_user_conversation
  ON public.conversation_participants (user_id, conversation_id);

CREATE INDEX IF NOT EXISTS idx_conversation_participants_user_last_message
  ON public.conversation_participants (user_id, last_message_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created_at
  ON public.messages (conversation_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.touch_track_on_addon_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track_id uuid;
BEGIN
  v_track_id := COALESCE(NEW.track_id, OLD.track_id);

  IF v_track_id IS NOT NULL THEN
    UPDATE public.tracks
    SET updated_at = now()
    WHERE id = v_track_id;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_track_on_addon_change ON public.track_addons;
CREATE TRIGGER trg_touch_track_on_addon_change
  AFTER INSERT OR UPDATE OR DELETE ON public.track_addons
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_track_on_addon_change();

WITH latest_messages AS (
  SELECT DISTINCT ON (m.conversation_id)
    m.conversation_id,
    m.id,
    m.created_at
  FROM public.messages m
  ORDER BY m.conversation_id, m.created_at DESC, m.id DESC
)
UPDATE public.conversation_participants cp
SET
  last_message_at = lm.created_at,
  last_message_id = lm.id
FROM latest_messages lm
WHERE cp.conversation_id = lm.conversation_id
  AND (
    cp.last_message_at IS DISTINCT FROM lm.created_at
    OR cp.last_message_id IS DISTINCT FROM lm.id
  );

CREATE OR REPLACE FUNCTION public.touch_conversation_participants_on_message_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.conversations
  SET updated_at = GREATEST(COALESCE(updated_at, NEW.created_at), NEW.created_at)
  WHERE id = NEW.conversation_id;

  UPDATE public.conversation_participants
  SET
    last_message_at = NEW.created_at,
    last_message_id = NEW.id
  WHERE conversation_id = NEW.conversation_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_conversation_participants_on_message_insert ON public.messages;
CREATE TRIGGER trg_touch_conversation_participants_on_message_insert
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_conversation_participants_on_message_insert();

CREATE OR REPLACE FUNCTION public.touch_conversation_participants_on_conversation_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF (
    NEW.status IS DISTINCT FROM OLD.status
    OR NEW.type IS DISTINCT FROM OLD.type
    OR NEW.closed_at IS DISTINCT FROM OLD.closed_at
    OR NEW.closed_by IS DISTINCT FROM OLD.closed_by
  ) THEN
    UPDATE public.conversation_participants
    SET last_message_at = last_message_at
    WHERE conversation_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_conversation_participants_on_conversation_update ON public.conversations;
CREATE TRIGGER trg_touch_conversation_participants_on_conversation_update
  AFTER UPDATE ON public.conversations
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_conversation_participants_on_conversation_update();

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
  WITH allowed AS (
    SELECT
      auth.uid() IS NOT NULL
      AND (
        auth.uid() = p_user_id
        OR public.is_admin(auth.uid())
        OR public.is_super_admin(auth.uid())
      ) AS ok
  )
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
  JOIN allowed a ON a.ok
  WHERE m.id = p_message_id
    AND EXISTS (
      SELECT 1
      FROM public.conversation_participants cp
      WHERE cp.conversation_id = m.conversation_id
        AND cp.user_id = p_user_id
    );
$$;

CREATE OR REPLACE FUNCTION public.get_sidebar_pending_counts(p_user_id uuid)
RETURNS TABLE (
  pending_tracks integer,
  pending_addons integer,
  total_pending integer
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
  tracks_count AS (
    SELECT count(*)::integer AS value
    FROM public.tracks t
    JOIN allowed a ON a.ok
    WHERE t.user_id = p_user_id
      AND t.status IN ('pending', 'processing')
  ),
  addons_count AS (
    SELECT count(*)::integer AS value
    FROM public.track_addons ta
    JOIN public.tracks t ON t.id = ta.track_id
    JOIN allowed a ON a.ok
    WHERE t.user_id = p_user_id
      AND ta.status IN ('pending', 'processing')
  )
  SELECT
    tc.value AS pending_tracks,
    ac.value AS pending_addons,
    (tc.value + ac.value) AS total_pending
  FROM tracks_count tc
  CROSS JOIN addons_count ac;
$$;

CREATE OR REPLACE FUNCTION public.get_qa_ticket_comment_counts(p_ticket_ids uuid[])
RETURNS TABLE (
  ticket_id uuid,
  comments_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    qc.ticket_id,
    count(*)::bigint AS comments_count
  FROM public.qa_comments qc
  WHERE qc.ticket_id = ANY(COALESCE(p_ticket_ids, ARRAY[]::uuid[]))
  GROUP BY qc.ticket_id;
$$;

CREATE OR REPLACE FUNCTION public.get_track_comments_counts(p_track_ids uuid[])
RETURNS TABLE (
  track_id uuid,
  comments_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    tc.track_id,
    count(*)::bigint AS comments_count
  FROM public.track_comments tc
  WHERE tc.track_id = ANY(COALESCE(p_track_ids, ARRAY[]::uuid[]))
  GROUP BY tc.track_id;
$$;

CREATE OR REPLACE FUNCTION public.get_users_roles(p_user_ids uuid[])
RETURNS TABLE (
  user_id uuid,
  role public.app_role
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ids.user_id,
    public.get_user_role(ids.user_id) AS role
  FROM (
    SELECT DISTINCT unnest(COALESCE(p_user_ids, ARRAY[]::uuid[])) AS user_id
  ) ids;
$$;

CREATE OR REPLACE FUNCTION public.get_users_subscription_tiers(p_user_ids uuid[])
RETURNS TABLE (
  user_id uuid,
  tier jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ids.user_id,
    public.get_user_subscription_tier(ids.user_id) AS tier
  FROM (
    SELECT DISTINCT unnest(COALESCE(p_user_ids, ARRAY[]::uuid[])) AS user_id
  ) ids;
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
GRANT EXECUTE ON FUNCTION public.get_message_notification_payload(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_sidebar_pending_counts(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_qa_ticket_comment_counts(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_track_comments_counts(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_users_roles(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_users_subscription_tiers(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_get_users_profiles(uuid[]) TO authenticated;
