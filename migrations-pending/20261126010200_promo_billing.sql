-- Keep the web generation debit and its two server-owned logs in one transaction.
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
  v_use_promo boolean := p_generation_params->'use_promo' = 'true'::jsonb;
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

  IF v_use_promo THEN
    IF p_request_id IS NULL OR p_provider_operation IS DISTINCT FROM 'generate'
      OR cardinality(p_track_ids) IS DISTINCT FROM 2 OR cardinality(p_addon_service_ids) > 0 THEN
      RAISE EXCEPTION 'promo_music_not_eligible';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('promo-music-request:' || p_user_id || ':' || p_request_id,0));
    IF EXISTS (SELECT 1 FROM public.generation_logs WHERE user_id=p_user_id
        AND (request_id=p_request_id OR track_id=ANY(p_track_ids))) THEN
      RAISE EXCEPTION 'promo_music_request_exists';
    END IF;
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
  IF v_use_promo THEN
    IF NOT promotions.reserve(p_user_id,'music',p_request_id) THEN RAISE EXCEPTION 'promo_unavailable'; END IF;
    v_discount_amount := v_generation_price;
    v_total := 0;
    SELECT balance INTO v_new_balance FROM public.profiles WHERE user_id=p_user_id;
  ELSIF v_total <= 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  ELSE
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
  END IF;

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
        p_generation_params - 'use_promo',
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

CREATE OR REPLACE FUNCTION public.begin_track_deposit_with_promo(
  p_deposit_id uuid,
  p_track_id uuid,
  p_user_id uuid,
  p_method text,
  p_file_hash text,
  p_metadata_hash text,
  p_performer_name text,
  p_lyrics_author text,
  p_use_promo boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track_title text;
  v_existing_status text;
  v_base_price integer := 0;
  v_effective_price integer := 0;
  v_free_total integer := 0;
  v_used integer := 0;
  v_balance_before numeric;
  v_balance_after numeric;
  v_price_value text;
  v_promo_applied boolean := false;
BEGIN
  IF p_method NOT IN ('internal', 'pdf', 'blockchain', 'nris', 'irma') THEN
    RAISE EXCEPTION 'Неизвестный метод депонирования';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  SELECT title INTO v_track_title
  FROM public.tracks
  WHERE id = p_track_id AND user_id = p_user_id;

  IF v_track_title IS NULL THEN
    RAISE EXCEPTION 'Трек не найден или не принадлежит вам';
  END IF;

  SELECT status INTO v_existing_status
  FROM public.track_deposits
  WHERE track_id = p_track_id AND method = p_method
  FOR UPDATE;

  IF v_existing_status = 'completed' THEN
    RAISE EXCEPTION 'Трек уже депонирован этим методом';
  ELSIF v_existing_status IN ('pending', 'processing') THEN
    RAISE EXCEPTION 'Депонирование этим методом уже выполняется';
  ELSIF v_existing_status = 'failed' THEN
    DELETE FROM public.track_deposits
    WHERE track_id = p_track_id AND method = p_method AND status = 'failed';
  END IF;

  SELECT value INTO v_price_value
  FROM public.settings
  WHERE key = 'deposit_price_' || p_method;

  v_base_price := CASE
    WHEN v_price_value ~ '^\d+$' THEN v_price_value::integer
    WHEN p_method = 'blockchain' THEN 300
    WHEN p_method = 'nris' THEN 500
    WHEN p_method = 'irma' THEN 300
    ELSE 0
  END;
  v_effective_price := GREATEST(0, v_base_price);

  IF p_method = 'blockchain' THEN
    SELECT COALESCE(sp.deposits_free_monthly, 0)
    INTO v_free_total
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.user_id = p_user_id
      AND us.status IN ('active', 'canceled')
      AND us.current_period_end > now()
    ORDER BY us.created_at DESC
    LIMIT 1;

    SELECT COALESCE(sum(source.used), 0)::integer
    INTO v_used
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

    IF v_used < v_free_total THEN
      v_effective_price := 0;
    END IF;
  END IF;

  IF p_use_promo AND p_method='blockchain' AND v_effective_price>0 THEN
    IF NOT promotions.reserve(p_user_id,'deposit',p_deposit_id) THEN
      RAISE EXCEPTION 'promo_unavailable';
    END IF;
    v_effective_price := 0;
    v_promo_applied := true;
  END IF;

  SELECT balance INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_balance_before IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;
  IF v_balance_before < v_effective_price THEN
    RAISE EXCEPTION 'Недостаточно средств. Требуется: % ₽, баланс: % ₽',
      v_effective_price, v_balance_before;
  END IF;

  v_balance_after := v_balance_before - v_effective_price;

  INSERT INTO public.track_deposits (
    id, track_id, user_id, method, status, file_hash, metadata_hash,
    performer_name, lyrics_author, price_rub
  ) VALUES (
    p_deposit_id, p_track_id, p_user_id, p_method, 'processing', p_file_hash,
    p_metadata_hash, p_performer_name, p_lyrics_author, v_effective_price
  );

  IF v_effective_price > 0 THEN
    UPDATE public.profiles
    SET balance = v_balance_after
    WHERE user_id = p_user_id;

    INSERT INTO public.balance_transactions (
      user_id, amount, balance_before, balance_after, type, description,
      reference_id, reference_type, metadata
    ) VALUES (
      p_user_id, -v_effective_price, v_balance_before, v_balance_after,
      'track_deposit', 'Депонирование трека «' || v_track_title || '» (' || p_method || ')',
      p_deposit_id, 'track_deposit',
      jsonb_build_object(
        'track_id', p_track_id,
        'track_title', v_track_title,
        'method', p_method,
        'tariff_free_deposit', false
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'deposit_id', p_deposit_id,
    'promo_applied', v_promo_applied,
    'price', v_effective_price,
    'balance_before', v_balance_before,
    'balance_after', v_balance_after,
    'tariff_free_deposit', p_method = 'blockchain' AND v_effective_price = 0 AND v_used < v_free_total,
    'free_remaining', CASE
      WHEN p_method = 'blockchain' THEN GREATEST(0, v_free_total - v_used - 1)
      ELSE 0
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.begin_track_deposit_with_promo(uuid, uuid, uuid, text, text, text, text, text, boolean)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_track_deposit_with_promo(uuid, uuid, uuid, text, text, text, text, text, boolean)
TO service_role;


-- The legacy deposit entry point and Studio retain their existing signature.
CREATE OR REPLACE FUNCTION public.begin_track_deposit(
  p_deposit_id uuid,p_track_id uuid,p_user_id uuid,p_method text,p_file_hash text,
  p_metadata_hash text,p_performer_name text,p_lyrics_author text
)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT public.begin_track_deposit_with_promo(p_deposit_id,p_track_id,p_user_id,p_method,
    p_file_hash,p_metadata_hash,p_performer_name,p_lyrics_author,false);
$$;

