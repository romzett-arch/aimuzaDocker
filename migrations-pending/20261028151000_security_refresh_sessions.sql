CREATE TABLE IF NOT EXISTS public.api_refresh_sessions (
 token_hash text PRIMARY KEY, user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 session_version integer NOT NULL, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.api_refresh_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.api_refresh_sessions FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.api_refresh_sessions TO service_role;
CREATE INDEX IF NOT EXISTS api_refresh_sessions_user_idx ON public.api_refresh_sessions(user_id);
-- Revoke pre-hardening access/refresh JWTs exactly once with this migration.
UPDATE auth.users SET raw_user_meta_data=jsonb_set(COALESCE(raw_user_meta_data,'{}'::jsonb),'{session_version}',
 to_jsonb(COALESCE(CASE WHEN raw_user_meta_data->>'session_version' ~ '^\d+$' THEN (raw_user_meta_data->>'session_version')::integer END,0)+1));
