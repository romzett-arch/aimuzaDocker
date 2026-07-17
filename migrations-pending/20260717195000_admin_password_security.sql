-- Align legacy impersonation logs with the current admin security contract.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'admin_id'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'admin_user_id'
  ) THEN
    ALTER TABLE public.impersonation_action_logs RENAME COLUMN admin_id TO admin_user_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'action'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'action_type'
  ) THEN
    ALTER TABLE public.impersonation_action_logs RENAME COLUMN action TO action_type;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'details'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'impersonation_action_logs' AND column_name = 'action_payload'
  ) THEN
    ALTER TABLE public.impersonation_action_logs RENAME COLUMN details TO action_payload;
  END IF;
END
$$;

ALTER TABLE public.impersonation_action_logs
  ADD COLUMN IF NOT EXISTS result_status text NOT NULL DEFAULT 'success',
  ADD COLUMN IF NOT EXISTS error_message text,
  ADD COLUMN IF NOT EXISTS ip_address text;

ALTER TABLE public.impersonation_action_logs
  ALTER COLUMN action_payload SET DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_impersonation_logs_admin
  ON public.impersonation_action_logs(admin_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_impersonation_logs_target
  ON public.impersonation_action_logs(target_user_id, created_at DESC);

