-- Reconcile missing admin_emails policies in environments where the original
-- table migration was applied incompletely.
DROP POLICY IF EXISTS "Admins can read admin email history" ON public.admin_emails;
CREATE POLICY "Admins can read admin email history"
ON public.admin_emails
FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can delete admin email history" ON public.admin_emails;
CREATE POLICY "Admins can delete admin email history"
ON public.admin_emails
FOR DELETE
TO authenticated
USING (public.is_admin(auth.uid()));
