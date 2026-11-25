-- Keep the API gateway's support staff rules and PostgreSQL row policies in sync.
ALTER POLICY qa_tickets_select_private ON public.qa_tickets
  USING (
    reporter_id = auth.uid()
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

ALTER POLICY qa_tickets_update_owner_or_admin ON public.qa_tickets
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

-- Each child table inherits the SELECT scope of its parent for ticket participants.
ALTER POLICY qa_comments_select_private ON public.qa_comments
  USING (EXISTS (SELECT 1 FROM public.qa_tickets WHERE id = qa_comments.ticket_id));

ALTER POLICY qa_comments_insert_owner_or_admin ON public.qa_comments
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (SELECT 1 FROM public.qa_tickets WHERE id = qa_comments.ticket_id)
  );

ALTER POLICY qa_ticket_events_select ON public.qa_ticket_events
  USING (EXISTS (SELECT 1 FROM public.qa_tickets WHERE id = qa_ticket_events.ticket_id));

ALTER POLICY support_ticket_events_select ON public.support_ticket_events
  USING (EXISTS (SELECT 1 FROM public.support_tickets WHERE id = support_ticket_events.ticket_id));

DROP POLICY IF EXISTS qa_tester_stats_select ON public.qa_tester_stats;
CREATE POLICY qa_tester_stats_select ON public.qa_tester_stats
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

CREATE POLICY qa_votes_select_own ON public.qa_votes
  FOR SELECT TO authenticated USING (user_id = auth.uid());
