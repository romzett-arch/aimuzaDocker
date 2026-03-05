-- Fix: "Prevent messages in closed conversations" must be RESTRICTIVE, not PERMISSIVE.
-- PERMISSIVE policies are OR'd: if any permissive policy passes, the operation is allowed.
-- The existing "Users can send messages to their conversations" (PERMISSIVE) always wins,
-- making the closed-conversation check useless.
-- RESTRICTIVE policies are AND'd: ALL restrictive policies must pass.

DROP POLICY IF EXISTS "Prevent messages in closed conversations" ON public.messages;

CREATE POLICY "Prevent messages in closed conversations"
ON public.messages
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
  NOT EXISTS (
    SELECT 1 FROM public.conversations
    WHERE conversations.id = messages.conversation_id
    AND conversations.type = 'admin_support'
    AND conversations.status = 'closed'
  )
);
