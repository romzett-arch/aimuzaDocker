-- Требуем явную докупку слотов до платной загрузки, без автосписания на INSERT.

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
  v_fallback_paid_price INTEGER := 0;
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

  IF jsonb_typeof(v_pricing) = 'array' AND jsonb_array_length(v_pricing) > 0 THEN
    v_fallback_paid_price := COALESCE((v_pricing->(jsonb_array_length(v_pricing) - 1)->>'price')::INTEGER, 0);
  END IF;
  v_fallback_paid_price := COALESCE(NULLIF(v_extra_price, 0), v_fallback_paid_price);

  IF v_monthly_hard_limit > 0 AND v_monthly_count >= v_monthly_hard_limit THEN
    IF v_pack_remaining > 0 THEN
      v_pack_applied := true;
      v_price := 0;
    ELSE
      RETURN jsonb_build_object(
        'can_upload', false,
        'price', v_fallback_paid_price,
        'is_free', false,
        'daily_count', v_daily_count,
        'monthly_count', v_monthly_count,
        'daily_limit', v_daily_limit,
        'monthly_free', v_monthly_free,
        'monthly_hard_limit', v_monthly_hard_limit,
        'reason', 'purchase_required',
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
          'price', v_fallback_paid_price,
          'is_free', false,
          'daily_count', v_daily_count,
          'monthly_count', v_monthly_count,
          'daily_limit', v_daily_limit,
          'monthly_free', v_monthly_free,
          'monthly_hard_limit', v_monthly_hard_limit,
          'reason', 'purchase_required',
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

      IF v_price > 0 THEN
        RETURN jsonb_build_object(
          'can_upload', false,
          'price', v_price,
          'is_free', false,
          'daily_count', v_daily_count,
          'monthly_count', v_monthly_count,
          'daily_limit', v_daily_limit,
          'monthly_free', v_monthly_free,
          'monthly_hard_limit', v_monthly_hard_limit,
          'reason', 'purchase_required',
          'tier_key', v_tier->>'tier_key',
          'pack_remaining', v_pack_remaining,
          'pack_applied', false
        );
      END IF;
    END IF;
  ELSIF NOT v_pack_applied THEN
    IF v_monthly_count >= v_monthly_free AND v_monthly_free > 0 THEN
      IF v_pack_remaining > 0 THEN
        v_pack_applied := true;
        v_price := 0;
      ELSE
        RETURN jsonb_build_object(
          'can_upload', false,
          'price', v_extra_price,
          'is_free', false,
          'daily_count', v_daily_count,
          'monthly_count', v_monthly_count,
          'daily_limit', v_daily_limit,
          'monthly_free', v_monthly_free,
          'monthly_hard_limit', v_monthly_hard_limit,
          'reason', 'purchase_required',
          'tier_key', v_tier->>'tier_key',
          'pack_remaining', v_pack_remaining,
          'pack_applied', false
        );
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

CREATE OR REPLACE FUNCTION public.consume_track_upload_charge(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing RECORD;
  v_limit JSONB;
  v_price INTEGER := 0;
  v_pack_applied BOOLEAN := false;
  v_pack_id UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_existing
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND track_id = p_track_id
    AND refunded_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'price_charged', v_existing.price_charged,
      'is_free', v_existing.is_free,
      'pack_slot_used', v_existing.pack_slot_used
    );
  END IF;

  v_limit := public.check_track_upload_limit(p_user_id);

  IF NOT COALESCE((v_limit->>'can_upload')::BOOLEAN, false) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', COALESCE(v_limit->>'reason', 'upload_not_allowed'),
      'limit', v_limit
    );
  END IF;

  v_price := COALESCE((v_limit->>'price')::INTEGER, 0);
  v_pack_applied := COALESCE((v_limit->>'pack_applied')::BOOLEAN, false);

  IF v_price > 0 AND NOT v_pack_applied THEN
    RETURN jsonb_build_object('success', false, 'error', 'purchase_required', 'limit', v_limit);
  END IF;

  IF v_pack_applied THEN
    SELECT id INTO v_pack_id
    FROM public.user_track_upload_packs
    WHERE user_id = p_user_id
      AND status = 'active'
      AND tracks_used < tracks_total
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_pack_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'upload_pack_not_found');
    END IF;

    UPDATE public.user_track_upload_packs
      SET tracks_used = tracks_used + 1,
          status = CASE WHEN tracks_used + 1 >= tracks_total THEN 'consumed' ELSE status END,
          updated_at = now()
      WHERE id = v_pack_id;
  END IF;

  IF v_price > 0 THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_balance_before IS NULL OR v_balance_before < v_price THEN
      RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'required', v_price);
    END IF;

    UPDATE public.profiles
      SET balance = balance - v_price
      WHERE user_id = p_user_id
      RETURNING balance INTO v_balance_after;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (p_user_id, -v_price, 'purchase', 'Загрузка трека (сверх лимита)', v_balance_before, v_balance_after);
  END IF;

  INSERT INTO public.user_track_uploads (user_id, track_id, price_charged, is_free, pack_id, pack_slot_used)
  VALUES (p_user_id, p_track_id, v_price, v_price = 0, v_pack_id, v_pack_applied);

  RETURN jsonb_build_object(
    'success', true,
    'price_charged', v_price,
    'is_free', v_price = 0,
    'pack_slot_used', v_pack_applied
  );
END;
$$;
