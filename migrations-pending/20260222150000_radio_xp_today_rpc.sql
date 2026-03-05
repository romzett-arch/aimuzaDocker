-- RPC function to get user's XP earned today from radio listens
CREATE OR REPLACE FUNCTION public.get_radio_xp_today(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_xp_today INTEGER;
BEGIN
  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  RETURN jsonb_build_object('xp_today', v_xp_today);
END;
$$;
