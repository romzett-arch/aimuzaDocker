DO $$
BEGIN
  IF to_regclass('public.messages') IS NOT NULL
     AND to_regclass('public.conversations') IS NOT NULL THEN
    DROP POLICY IF EXISTS "Prevent messages in closed conversations" ON public.messages;

    CREATE POLICY "Prevent messages in closed conversations"
    ON public.messages
    AS RESTRICTIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (
      NOT EXISTS (
        SELECT 1
        FROM public.conversations
        WHERE conversations.id = messages.conversation_id
          AND conversations.type = 'admin_support'
          AND conversations.status = 'closed'
      )
    );
  END IF;
END $$;
