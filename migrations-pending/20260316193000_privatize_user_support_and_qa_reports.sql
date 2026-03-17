-- Делает пользовательские тикеты и QA-репорты приватными и разрешает удаление своих обращений.

DROP POLICY IF EXISTS "Users can delete own tickets" ON public.support_tickets;
CREATE POLICY "Users can delete own tickets"
ON public.support_tickets
FOR DELETE TO authenticated
USING (auth.uid() = user_id);

ALTER TABLE IF EXISTS public.qa_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.qa_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.qa_votes ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record RECORD;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qa_tickets'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.qa_tickets', policy_record.policyname);
  END LOOP;

  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qa_comments'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.qa_comments', policy_record.policyname);
  END LOOP;

  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qa_votes'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.qa_votes', policy_record.policyname);
  END LOOP;
END $$;

CREATE POLICY "qa_tickets_select_private"
ON public.qa_tickets
FOR SELECT TO authenticated
USING (
  auth.uid() = reporter_id
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "qa_tickets_insert_own"
ON public.qa_tickets
FOR INSERT TO authenticated
WITH CHECK (auth.uid() = reporter_id);

CREATE POLICY "qa_tickets_update_owner_or_admin"
ON public.qa_tickets
FOR UPDATE TO authenticated
USING (
  auth.uid() = reporter_id
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
)
WITH CHECK (
  auth.uid() = reporter_id
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "qa_tickets_delete_owner_or_admin"
ON public.qa_tickets
FOR DELETE TO authenticated
USING (
  auth.uid() = reporter_id
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "qa_comments_select_private"
ON public.qa_comments
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.qa_tickets AS tickets
    WHERE tickets.id = qa_comments.ticket_id
      AND (
        tickets.reporter_id = auth.uid()
        OR public.has_role(auth.uid(), 'admin')
        OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

CREATE POLICY "qa_comments_insert_owner_or_admin"
ON public.qa_comments
FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1
    FROM public.qa_tickets AS tickets
    WHERE tickets.id = qa_comments.ticket_id
      AND (
        tickets.reporter_id = auth.uid()
        OR public.has_role(auth.uid(), 'admin')
        OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

CREATE POLICY "qa_comments_admin_manage"
ON public.qa_comments
FOR ALL TO authenticated
USING (
  public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
)
WITH CHECK (
  public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "qa_votes_admin_manage"
ON public.qa_votes
FOR ALL TO authenticated
USING (
  public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
)
WITH CHECK (
  public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);
