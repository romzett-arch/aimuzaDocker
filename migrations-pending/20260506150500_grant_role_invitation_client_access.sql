-- Ensure authenticated users can see and respond to their role invitations through Supabase client.

GRANT SELECT, INSERT, UPDATE ON public.role_invitations TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.role_invitation_permissions TO authenticated;
GRANT SELECT, INSERT ON public.role_change_logs TO authenticated;
