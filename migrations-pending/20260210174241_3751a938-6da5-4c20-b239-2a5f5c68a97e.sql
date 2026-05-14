
-- Add admin dialog support to conversations
ALTER TABLE public.conversations 
ADD COLUMN IF NOT EXISTS type text NOT NULL DEFAULT 'personal',
ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
ADD COLUMN IF NOT EXISTS closed_by uuid REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS closed_at timestamptz;

-- Index for quick filtering
CREATE INDEX IF NOT EXISTS idx_conversations_type ON public.conversations(type);
CREATE INDEX IF NOT EXISTS idx_conversations_status ON public.conversations(status);

-- Function to close admin dialog (only super_admin)
CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check caller is super_admin
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can close admin conversations';
  END IF;

  UPDATE public.conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';
END;
$$;

-- Function to delete closed admin conversation (for user)
CREATE OR REPLACE FUNCTION public.delete_closed_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type text;
  v_status text;
  v_is_participant boolean;
BEGIN
  SELECT c.type, c.status, EXISTS(
    SELECT 1 FROM conversation_participants cp WHERE cp.conversation_id = c.id AND cp.user_id = auth.uid()
  ) INTO v_type, v_status, v_is_participant
  FROM conversations c WHERE c.id = p_conversation_id;

  IF NOT v_is_participant THEN
    RAISE EXCEPTION 'Not a participant';
  END IF;

  -- Users can only delete closed admin conversations
  IF v_type = 'admin_support' AND v_status = 'closed' THEN
    DELETE FROM conversation_participants WHERE conversation_id = p_conversation_id AND user_id = auth.uid();
  ELSIF v_type = 'personal' THEN
    DELETE FROM conversation_participants WHERE conversation_id = p_conversation_id AND user_id = auth.uid();
  ELSE
    RAISE EXCEPTION 'Cannot delete active admin conversation';
  END IF;
END;
$$;
