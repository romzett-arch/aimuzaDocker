-- Keep is_user_blocked aligned with the canonical account-block table.

CREATE OR REPLACE FUNCTION public.is_user_blocked(_user_id UUID DEFAULT NULL::uuid)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_blocks ub
    WHERE ub.user_id = COALESCE(_user_id, auth.uid())
      AND COALESCE(ub.is_active, true)
      AND (ub.expires_at IS NULL OR ub.expires_at > now())
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_user_blocked(UUID) TO authenticated;
