DROP TRIGGER IF EXISTS trg_notify_role_invitations ON public.role_invitations;
CREATE TRIGGER trg_notify_role_invitations
  AFTER INSERT OR UPDATE OR DELETE ON public.role_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_role_invitation_permissions ON public.role_invitation_permissions;
CREATE TRIGGER trg_notify_role_invitation_permissions
  AFTER INSERT OR UPDATE OR DELETE ON public.role_invitation_permissions
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_table_change();
