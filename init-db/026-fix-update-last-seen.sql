-- Fix update_last_seen: restore no-arg version using auth.uid()
-- 006-audit-tables.sql overwrote with update_last_seen(p_user_id uuid), but frontend calls rpc() without args.
-- This breaks last_seen_at updates → online status fallback never works.

CREATE OR REPLACE FUNCTION public.update_last_seen()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles 
  SET last_seen_at = now() 
  WHERE user_id = auth.uid();
END;
$$;
