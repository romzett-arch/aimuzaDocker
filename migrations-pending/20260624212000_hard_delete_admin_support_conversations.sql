-- Deleting an admin-created support conversation must remove its history,
-- not archive and resurrect the same thread later.

CREATE OR REPLACE FUNCTION public.messaging_archive_conversation(
  p_conversation_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_type text;
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

  SELECT COALESCE(type, 'personal')
  INTO v_conversation_type
  FROM public.conversations
  WHERE id = p_conversation_id;

  IF v_conversation_type IN ('personal', 'direct', 'admin_support') THEN
    DELETE FROM public.conversations
    WHERE id = p_conversation_id;

    RETURN TRUE;
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

GRANT EXECUTE ON FUNCTION public.messaging_archive_conversation(uuid, uuid) TO authenticated;
