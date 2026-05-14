
-- RPC to create admin_support conversation (super_admin only)
CREATE OR REPLACE FUNCTION public.create_admin_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
  v_existing_id uuid;
BEGIN
  -- Check caller is super_admin
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can create admin conversations';
  END IF;

  -- Check if admin_support conversation already exists between these two users
  SELECT c.id INTO v_existing_id
  FROM conversations c
  JOIN conversation_participants cp1 ON cp1.conversation_id = c.id AND cp1.user_id = auth.uid()
  JOIN conversation_participants cp2 ON cp2.conversation_id = c.id AND cp2.user_id = p_target_user_id
  WHERE c.type = 'admin_support'
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- Reopen if closed
    UPDATE conversations SET status = 'active', closed_by = NULL, closed_at = NULL
    WHERE id = v_existing_id AND status = 'closed';
    RETURN v_existing_id;
  END IF;

  -- Create new conversation
  INSERT INTO conversations (type, status)
  VALUES ('admin_support', 'active')
  RETURNING id INTO v_conversation_id;

  -- Add participants
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES 
    (v_conversation_id, auth.uid()),
    (v_conversation_id, p_target_user_id);

  RETURN v_conversation_id;
END;
$$;
