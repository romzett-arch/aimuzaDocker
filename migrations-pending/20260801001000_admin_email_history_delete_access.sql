-- Let authenticated administrators read and delete email history rows.
-- The existing admin_emails RLS policy remains the authorization boundary.
GRANT SELECT, DELETE ON TABLE public.admin_emails TO authenticated;
