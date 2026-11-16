CREATE OR REPLACE FUNCTION public.get_my_marketplace_commission()
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT tier.marketplace_commission
    FROM public.forum_user_stats AS stats
    JOIN public.reputation_tiers AS tier ON tier.key = stats.tier
    WHERE stats.user_id = (SELECT auth.uid())
  ), 0.10);
$$;

REVOKE ALL ON FUNCTION public.get_my_marketplace_commission() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_marketplace_commission() TO authenticated;
