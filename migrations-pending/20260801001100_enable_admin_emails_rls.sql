-- The policy already exists, but some environments have admin_emails RLS disabled.
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
ALTER TABLE public.admin_emails ENABLE ROW LEVEL SECURITY;
