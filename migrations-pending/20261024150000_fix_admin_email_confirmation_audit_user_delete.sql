-- Audit records contain personal identifiers and must not prevent a complete
-- account deletion. The records are technical evidence of an admin action, so
-- remove them together with either referenced account.
ALTER TABLE public.admin_email_confirmation_audit
  DROP CONSTRAINT IF EXISTS admin_email_confirmation_audit_admin_user_id_fkey,
  DROP CONSTRAINT IF EXISTS admin_email_confirmation_audit_target_user_id_fkey;

ALTER TABLE public.admin_email_confirmation_audit
  ADD CONSTRAINT admin_email_confirmation_audit_admin_user_id_fkey
    FOREIGN KEY (admin_user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
  ADD CONSTRAINT admin_email_confirmation_audit_target_user_id_fkey
    FOREIGN KEY (target_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
