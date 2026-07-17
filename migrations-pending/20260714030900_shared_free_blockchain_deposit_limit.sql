CREATE OR REPLACE FUNCTION public.check_deposit_limit(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_free_deposits integer := 0;
  v_used_deposits integer := 0;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object(
      'free_remaining', 0, 'free_total', 0, 'used_this_month', 0,
      'is_free', false, 'error', 'unauthorized'
    );
  END IF;

  SELECT COALESCE(sp.deposits_free_monthly, 0)
  INTO v_free_deposits
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  -- The tariff quota is common for blockchain deposits of tracks and lyrics.
  SELECT COALESCE(sum(source.used), 0)::integer
  INTO v_used_deposits
  FROM (
    SELECT count(*)::integer AS used
    FROM public.track_deposits
    WHERE user_id = p_user_id
      AND method = 'blockchain'
      AND status IN ('processing', 'completed')
      AND created_at >= date_trunc('month', now())
    UNION ALL
    SELECT count(*)::integer AS used
    FROM public.lyrics_deposits
    WHERE user_id = p_user_id
      AND method = 'blockchain'
      AND status IN ('pending', 'processing', 'completed')
      AND created_at >= date_trunc('month', now())
  ) source;

  RETURN jsonb_build_object(
    'free_remaining', GREATEST(0, v_free_deposits - v_used_deposits),
    'free_total', v_free_deposits,
    'used_this_month', v_used_deposits,
    'is_free', v_used_deposits < v_free_deposits
  );
END;
$$;
