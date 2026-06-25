-- Hide active account-blocked authors from public catalog without exposing user_blocks rows.

CREATE OR REPLACE FUNCTION public.get_catalog_visible_author_ids(p_user_ids UUID[])
RETURNS TABLE(user_id UUID)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT requested.user_id
  FROM unnest(COALESCE(p_user_ids, ARRAY[]::UUID[])) AS requested(user_id)
  WHERE requested.user_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_blocks ub
      WHERE ub.user_id = requested.user_id
        AND ub.is_active = true
        AND (ub.expires_at IS NULL OR ub.expires_at > now())
    );
$$;

GRANT EXECUTE ON FUNCTION public.get_catalog_visible_author_ids(UUID[]) TO anon, authenticated;
