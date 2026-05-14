
-- 1. Allow all admins (not just super_admin) to view impersonation logs
DROP POLICY IF EXISTS "Super admins can view impersonation logs" ON public.impersonation_action_logs;

CREATE POLICY "Admins can view impersonation logs"
ON public.impersonation_action_logs
FOR SELECT
TO authenticated
USING (
  public.has_role(auth.uid(), 'admin'::app_role)
  OR public.has_role(auth.uid(), 'super_admin'::app_role)
);

-- 2. Auto-cleanup expired email verifications (older than 1 hour)
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_verifications()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.email_verifications
  WHERE expires_at < now() - interval '1 hour';
END;
$$;

-- 3. Create a cron-like trigger: clean up on every new insert
CREATE OR REPLACE FUNCTION public.trigger_cleanup_email_verifications()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Clean up expired records on each new verification attempt
  DELETE FROM public.email_verifications
  WHERE expires_at < now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cleanup_email_verifications ON public.email_verifications;
CREATE TRIGGER trg_cleanup_email_verifications
BEFORE INSERT ON public.email_verifications
FOR EACH STATEMENT
EXECUTE FUNCTION public.trigger_cleanup_email_verifications();
