CREATE TABLE IF NOT EXISTS public.ai_request_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'timeweb',
  source text NOT NULL,
  action text NOT NULL,
  reason text NOT NULL,
  entity_type text,
  entity_id text,
  model text,
  request_chars integer,
  request_messages integer,
  max_tokens integer,
  prompt_tokens integer,
  completion_tokens integer,
  total_tokens integer,
  duration_ms integer,
  http_status integer,
  status text NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'completed', 'failed')),
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);

CREATE INDEX IF NOT EXISTS ai_request_logs_created_at_idx
  ON public.ai_request_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS ai_request_logs_source_created_at_idx
  ON public.ai_request_logs (source, created_at DESC);

ALTER TABLE public.ai_request_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can read AI request logs" ON public.ai_request_logs;
CREATE POLICY "Admins can read AI request logs"
  ON public.ai_request_logs
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

REVOKE ALL ON public.ai_request_logs FROM anon, authenticated;
GRANT SELECT ON public.ai_request_logs TO authenticated;
GRANT ALL ON public.ai_request_logs TO service_role;

COMMENT ON TABLE public.ai_request_logs IS
  'Audit trail for external AI calls. Prompts and credentials are intentionally not stored.';
