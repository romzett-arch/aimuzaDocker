-- Validate ownership before writing pending generation logs.
CREATE OR REPLACE FUNCTION public.debit_for_generation_v6(
  p_user_id UUID,
  p_addon_service_ids UUID[] DEFAULT '{}',
  p_description TEXT DEFAULT 'Генерация трека Suno V6',
  p_request_id UUID DEFAULT NULL,
  p_track_ids UUID[] DEFAULT '{}',
  p_provider_operation TEXT DEFAULT 'generate',
  p_generation_params JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  new_balance INTEGER,
  amount_debited INTEGER,
  generation_service_id UUID,
  generation_sale_price_rub INTEGER,
  generation_base_cost_credits NUMERIC,
  discount_amount INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_service_id UUID;
  v_generation_price INTEGER;
  v_base_cost_credits NUMERIC;
  v_discount_percent INTEGER;
  v_discount_amount INTEGER := 0;
  v_has_subscription BOOLEAN;
  v_addons_total INTEGER := 0;
  v_sale_price INTEGER;
  v_total INTEGER;
  v_new_balance INTEGER;
  v_track_count INTEGER;
  v_share_cost INTEGER;
  v_share_sale INTEGER;
  v_share_discount INTEGER;
  v_i INTEGER;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR (v_caller != p_user_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT id, price_rub, base_cost_credits
  INTO v_service_id, v_generation_price, v_base_cost_credits
  FROM public.addon_services
  WHERE name = 'generate_music_v6' AND is_active = true
  LIMIT 1;

  IF v_service_id IS NULL OR COALESCE(v_generation_price, 0) <= 0 THEN
    RAISE EXCEPTION 'Generation service is unavailable';
  END IF;

  SELECT COALESCE((value)::integer, 20) INTO v_discount_percent
  FROM public.settings WHERE key = 'subscriber_discount_percent' LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM public.user_subscriptions s
    WHERE s.user_id = p_user_id
      AND s.status IN ('active', 'canceled')
      AND s.current_period_end > now()
  ) INTO v_has_subscription;

  v_sale_price := v_generation_price;
  IF v_has_subscription AND v_discount_percent > 0 THEN
    v_discount_amount := v_generation_price * v_discount_percent / 100;
    v_sale_price := v_generation_price - v_discount_amount;
  END IF;

  IF array_length(p_addon_service_ids, 1) > 0 THEN
    SELECT COALESCE(SUM(price_rub), 0)::integer INTO v_addons_total
    FROM public.addon_services
    WHERE id = ANY(p_addon_service_ids) AND is_active = true;
  END IF;

  v_total := v_sale_price + v_addons_total;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_total
  WHERE user_id = p_user_id AND balance >= v_total
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, balance_before, balance_after)
  VALUES
    (p_user_id, -v_total, 'debit', p_description, v_new_balance + v_total, v_new_balance);

  -- Pending generation logs, split across the requested track variants the
  -- same way the previous client-side insert did: first track takes the
  -- ceiling share, the last track takes the remainder.
  v_track_count := COALESCE(array_length(p_track_ids, 1), 0);
  IF v_track_count > 0 THEN
    IF p_provider_operation NOT IN ('generate', 'upload_cover') THEN
      RAISE EXCEPTION 'Invalid provider operation';
    END IF;
    IF length(p_generation_params::text) > 20000 THEN
      RAISE EXCEPTION 'Generation params too large';
    END IF;
    IF (SELECT COUNT(DISTINCT t) FROM unnest(p_track_ids) AS t) <> v_track_count THEN
      RAISE EXCEPTION 'Duplicate track ids';
    END IF;

    IF (
      SELECT COUNT(*)
      FROM public.tracks
      WHERE id = ANY(p_track_ids) AND user_id = p_user_id
    ) <> v_track_count THEN
      RAISE EXCEPTION 'Unauthorized track ids';
    END IF;

    v_share_cost := ceil(v_total::numeric / v_track_count)::integer;
    v_share_sale := ceil(v_sale_price::numeric / v_track_count)::integer;
    v_share_discount := ceil(v_discount_amount::numeric / v_track_count)::integer;

    FOR v_i IN 1..v_track_count LOOP
      INSERT INTO public.generation_logs (
        user_id, track_id, request_id, service_id, service_name,
        provider, provider_operation, provider_model, model,
        cost_rub, sale_price_rub, discount_rub, base_cost_credits,
        generation_params, status
      ) VALUES (
        p_user_id,
        p_track_ids[v_i],
        p_request_id,
        v_service_id,
        'generate_music_v6',
        'sunoapi',
        p_provider_operation,
        'V6',
        'V6',
        CASE WHEN v_i < v_track_count THEN v_share_cost
             ELSE v_total - v_share_cost * (v_track_count - 1) END,
        CASE WHEN v_i < v_track_count THEN v_share_sale
             ELSE v_sale_price - v_share_sale * (v_track_count - 1) END,
        CASE WHEN v_i < v_track_count THEN v_share_discount
             ELSE v_discount_amount - v_share_discount * (v_track_count - 1) END,
        round(COALESCE(v_base_cost_credits, 0) / v_track_count, 2),
        p_generation_params,
        'pending'
      );
    END LOOP;
  END IF;

  RETURN QUERY SELECT
    v_new_balance,
    v_total,
    v_service_id,
    v_sale_price,
    COALESCE(v_base_cost_credits, 0),
    v_discount_amount;
END;
$$;
