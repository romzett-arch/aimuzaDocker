-- Match the gateway: published bounties are visible, support can review them,
-- and only administrators can manage them.
DROP POLICY IF EXISTS qa_bounties_select ON public.qa_bounties;
DROP POLICY IF EXISTS qa_bounties_manage ON public.qa_bounties;

CREATE POLICY qa_bounties_select ON public.qa_bounties
  FOR SELECT TO anon, authenticated
  USING (is_active IS TRUE AND (expires_at IS NULL OR expires_at > now()));

CREATE POLICY qa_bounties_staff_select ON public.qa_bounties
  FOR SELECT TO authenticated
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

CREATE POLICY qa_bounties_admin_insert ON public.qa_bounties
  FOR INSERT TO authenticated
  WITH CHECK (
    created_by = auth.uid()
    AND (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  );

CREATE POLICY qa_bounties_admin_update ON public.qa_bounties
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

CREATE POLICY qa_bounties_admin_delete ON public.qa_bounties
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));
