DO $$
BEGIN
  IF to_regclass('public.messages') IS NOT NULL
     AND to_regclass('public.conversations') IS NOT NULL THEN
    CREATE POLICY "Prevent messages in closed conversations"
    ON public.messages FOR INSERT
    TO authenticated
    WITH CHECK (
      NOT EXISTS (
        SELECT 1
        FROM public.conversations
        WHERE conversations.id = conversation_id
          AND conversations.status = 'closed'
      )
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can close admin conversations';
  END IF;

  UPDATE conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found or already closed';
  END IF;
END;
$$;
