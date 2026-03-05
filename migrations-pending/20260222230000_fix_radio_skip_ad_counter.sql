-- Fix radio_skip_ad: increment clicks (skips) instead of impressions on ad skip.
-- impressions are already tracked by the ad-scheduler when ad is sent to clients.

DROP FUNCTION IF EXISTS public.radio_skip_ad(UUID, UUID);

CREATE OR REPLACE FUNCTION public.radio_skip_ad(
  p_user_id UUID,
  p_ad_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_skip_price INTEGER := 5;
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_skip_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - v_skip_price WHERE user_id = p_user_id;
  UPDATE public.radio_ad_placements SET clicks = clicks + 1 WHERE id = p_ad_id;

  RETURN jsonb_build_object('ok', true, 'charged', v_skip_price);
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.radio_skip_ad(UUID, UUID) TO authenticated;
  END IF;
END $$;
