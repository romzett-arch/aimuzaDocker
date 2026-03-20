-- Ручная докупка загрузок треков: поштучно и пакетами с подтверждением на фронте.

CREATE OR REPLACE FUNCTION public.check_track_upload_limit(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
  v_daily_count INTEGER;
  v_monthly_count INTEGER;
  v_daily_limit INTEGER;
  v_monthly_free INTEGER;
  v_monthly_hard_limit INTEGER;
  v_extra_price INTEGER;
  v_pricing JSONB;
  v_price INTEGER := 0;
  v_is_free_tier BOOLEAN;
  v_nth INTEGER;
  v_item JSONB;
  v_pack_remaining INTEGER := 0;
  v_pack_applied BOOLEAN := false;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('can_upload', false, 'price', 0, 'reason', 'unauthorized');
  END IF;

  v_tier := public.get_user_subscription_tier(p_user_id);
  v_is_free_tier := (v_tier->>'tier_key') = 'free';
  v_daily_limit := COALESCE((v_tier->>'tracks_free_daily')::INTEGER, 0);
  v_monthly_free := COALESCE((v_tier->>'tracks_free_monthly')::INTEGER, 0);
  v_monthly_hard_limit := COALESCE((v_tier->>'tracks_monthly_hard_limit')::INTEGER, 0);
  v_extra_price := COALESCE((v_tier->>'extra_track_price')::INTEGER, 0);
  v_pricing := COALESCE(v_tier->'free_track_pricing', '[]'::jsonb);

  SELECT COUNT(*) INTO v_daily_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND refunded_at IS NULL
    AND upload_date = CURRENT_DATE;

  SELECT COUNT(*) INTO v_monthly_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND refunded_at IS NULL
    AND upload_date >= date_trunc('month', CURRENT_DATE)::DATE;

  SELECT COALESCE(SUM(GREATEST(tracks_total - tracks_used, 0)), 0) INTO v_pack_remaining
  FROM public.user_track_upload_packs
  WHERE user_id = p_user_id
    AND status = 'active';

  IF v_monthly_hard_limit > 0 AND v_monthly_count >= v_monthly_hard_limit THEN
    IF v_pack_remaining > 0 THEN
      v_pack_applied := true;
      v_price := 0;
    ELSE
      RETURN jsonb_build_object(
        'can_upload', false,
        'price', 0,
        'is_free', false,
        'daily_count', v_daily_count,
        'monthly_count', v_monthly_count,
        'daily_limit', v_daily_limit,
        'monthly_free', v_monthly_free,
        'monthly_hard_limit', v_monthly_hard_limit,
        'reason', 'monthly_limit_reached',
        'tier_key', v_tier->>'tier_key',
        'pack_remaining', v_pack_remaining,
        'pack_applied', false
      );
    END IF;
  END IF;

  IF NOT v_pack_applied AND v_is_free_tier AND jsonb_typeof(v_pricing) = 'array' AND jsonb_array_length(v_pricing) > 0 THEN
    IF v_daily_limit > 0 AND v_daily_count >= v_daily_limit THEN
      IF v_pack_remaining > 0 THEN
        v_pack_applied := true;
        v_price := 0;
      ELSE
        RETURN jsonb_build_object(
          'can_upload', false,
          'price', 0,
          'is_free', false,
          'daily_count', v_daily_count,
          'monthly_count', v_monthly_count,
          'daily_limit', v_daily_limit,
          'monthly_free', v_monthly_free,
          'monthly_hard_limit', v_monthly_hard_limit,
          'reason', 'daily_limit_reached',
          'tier_key', v_tier->>'tier_key',
          'pack_remaining', v_pack_remaining,
          'pack_applied', false
        );
      END IF;
    END IF;

    IF NOT v_pack_applied THEN
      v_nth := v_daily_count + 1;

      FOR v_item IN SELECT * FROM jsonb_array_elements(v_pricing)
      LOOP
        IF (v_item->>'nth')::INTEGER = v_nth THEN
          v_price := (v_item->>'price')::INTEGER;
          EXIT;
        END IF;
      END LOOP;

      IF v_price = 0 AND v_nth > 1 THEN
        v_price := COALESCE((v_pricing->(jsonb_array_length(v_pricing) - 1)->>'price')::INTEGER, 0);
      END IF;
    END IF;
  ELSIF NOT v_pack_applied THEN
    IF v_monthly_count >= v_monthly_free AND v_monthly_free > 0 THEN
      IF v_pack_remaining > 0 THEN
        v_pack_applied := true;
        v_price := 0;
      ELSE
        v_price := v_extra_price;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'can_upload', true,
    'price', v_price,
    'is_free', v_price = 0,
    'daily_count', v_daily_count,
    'monthly_count', v_monthly_count,
    'daily_limit', v_daily_limit,
    'monthly_free', v_monthly_free,
    'monthly_hard_limit', v_monthly_hard_limit,
    'tier_key', v_tier->>'tier_key',
    'pack_remaining', v_pack_remaining,
    'pack_applied', v_pack_applied
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_track_upload_units(
  p_user_id UUID,
  p_quantity INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
  v_pack_price INTEGER;
  v_unit_price INTEGER;
  v_total_price INTEGER;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
  v_pack_id UUID;
  v_pack_key TEXT;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 99 THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_quantity');
  END IF;

  v_tier := public.get_user_subscription_tier(p_user_id);

  SELECT price_rub INTO v_pack_price
  FROM public.addon_services
  WHERE name = 'track_upload_pack_10'
    AND is_active = true
  LIMIT 1;

  IF v_pack_price IS NULL OR v_pack_price <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'pack_not_found');
  END IF;

  v_unit_price := COALESCE(NULLIF((v_tier->>'extra_track_price')::INTEGER, 0), CEIL(v_pack_price::NUMERIC / 10.0)::INTEGER);
  v_total_price := v_unit_price * p_quantity;
  v_pack_key := format('track_upload_units_%s', p_quantity);

  SELECT balance INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_balance_before IS NULL OR v_balance_before < v_total_price THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'insufficient_balance',
      'required', v_total_price,
      'balance', COALESCE(v_balance_before, 0)
    );
  END IF;

  UPDATE public.profiles
    SET balance = balance - v_total_price
    WHERE user_id = p_user_id
    RETURNING balance INTO v_balance_after;

  INSERT INTO public.user_track_upload_packs (user_id, pack_key, tracks_total, price_paid)
  VALUES (p_user_id, v_pack_key, p_quantity, v_total_price)
  RETURNING id INTO v_pack_id;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after)
  VALUES
    (
      p_user_id,
      -v_total_price,
      'purchase',
      format('Докупка %s загрузок треков', p_quantity),
      v_pack_id,
      'track_upload_pack',
      v_balance_before,
      v_balance_after
    );

  RETURN jsonb_build_object(
    'success', true,
    'pack_id', v_pack_id,
    'quantity', p_quantity,
    'unit_price', v_unit_price,
    'price_paid', v_total_price,
    'new_balance', v_balance_after
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_track_upload_units(UUID, INTEGER) TO authenticated;
