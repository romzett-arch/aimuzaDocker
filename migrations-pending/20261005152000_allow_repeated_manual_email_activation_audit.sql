-- A user can be explicitly unconfirmed by an existing admin action and later
-- confirmed again. Keep every real state transition in the append-only audit.
ALTER TABLE public.admin_email_confirmation_audit
  DROP CONSTRAINT IF EXISTS admin_email_confirmation_audit_target_user_id_key;
