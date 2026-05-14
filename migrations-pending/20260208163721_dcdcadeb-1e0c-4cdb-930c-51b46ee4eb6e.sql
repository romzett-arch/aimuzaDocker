DO $$
BEGIN
  IF to_regclass('public.messages') IS NOT NULL THEN
    DROP POLICY IF EXISTS "Users can view messages in their conversations" ON public.messages;
    DROP POLICY IF EXISTS "Users can update own messages" ON public.messages;

    DROP POLICY IF EXISTS "Users can view their conversation messages" ON public.messages;
    CREATE POLICY "Users can view their conversation messages"
    ON public.messages FOR SELECT
    TO authenticated
    USING (deleted_at IS NULL AND is_participant_in_conversation(auth.uid(), conversation_id));

    CREATE POLICY "Admins can view all messages"
    ON public.messages FOR SELECT
    TO authenticated
    USING (is_admin(auth.uid()));

    DROP POLICY IF EXISTS "Users can send messages to their conversations" ON public.messages;
    CREATE POLICY "Users can send messages to their conversations"
    ON public.messages FOR INSERT
    TO authenticated
    WITH CHECK (
      sender_id = auth.uid()
      AND EXISTS (
        SELECT 1 FROM conversation_participants
        WHERE conversation_participants.conversation_id = messages.conversation_id
          AND conversation_participants.user_id = auth.uid()
      )
    );

    DROP POLICY IF EXISTS "Users can update their own messages" ON public.messages;
    CREATE POLICY "Users can update their own messages"
    ON public.messages FOR UPDATE
    TO authenticated
    USING (sender_id = auth.uid() OR is_admin(auth.uid()))
    WITH CHECK (sender_id = auth.uid() OR is_admin(auth.uid()));

    DROP POLICY IF EXISTS "Users can delete their own messages" ON public.messages;
    CREATE POLICY "Users can delete their own messages"
    ON public.messages FOR DELETE
    TO authenticated
    USING (sender_id = auth.uid() OR is_admin(auth.uid()));
  END IF;
END $$;

DROP POLICY IF EXISTS "Users can only view own payments" ON public.payments;
DROP POLICY IF EXISTS "Allow insert for authenticated users" ON public.payments;
CREATE POLICY "Authenticated users can insert own payments"
ON public.payments FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id OR is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can update payments" ON public.payments;
CREATE POLICY "Admins can update payments"
ON public.payments FOR UPDATE
TO authenticated
USING (is_admin(auth.uid()))
WITH CHECK (is_admin(auth.uid()));
