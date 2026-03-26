CREATE OR REPLACE FUNCTION public.is_email_registered(p_email text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = auth, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users
    WHERE lower(email) = lower(trim(p_email))
  );
$$;

REVOKE ALL ON FUNCTION public.is_email_registered(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_registered(text) TO anon;
GRANT EXECUTE ON FUNCTION public.is_email_registered(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_email_registered(text) TO service_role;
