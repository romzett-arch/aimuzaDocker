-- Fix: платный буст не должен молча тратить бесплатный лимит подписки
-- и оба сценария (платный/бесплатный) должны отражаться в истории операций.

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER,
  p_use_subscription_boost BOOLEAN
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_user_balance NUMERIC;
  v_new_balance NUMERIC;
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMP WITH TIME ZONE;
  v_boost_type TEXT;
  v_track_title TEXT;
  v_track_public BOOLEAN;
  v_free_boosts INTEGER := 0;
  v_used_boosts_today INTEGER := 0;
  v_sub_duration INTEGER := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;

  SELECT title, is_public
  INTO v_track_title, v_track_public
  FROM public.tracks
  WHERE id = p_track_id
    AND user_id = v_user_id;

  IF v_track_title IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;

  IF NOT v_track_public THEN
    RETURN json_build_object('success', false, 'error', 'Трек должен быть публичным для продвижения в ленте');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.track_promotions
    WHERE track_id = p_track_id
      AND is_active = true
      AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Трек уже продвигается');
  END IF;

  SELECT COALESCE(sp.boosts_per_day, 0), COALESCE(sp.boost_duration_hours, 1)
  INTO v_free_boosts, v_sub_duration
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = v_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  IF p_use_subscription_boost THEN
    IF v_free_boosts <= 0 THEN
      RETURN json_build_object('success', false, 'error', 'На вашем тарифе нет бесплатных бустов');
    END IF;

    SELECT COUNT(*)
    INTO v_used_boosts_today
    FROM public.track_promotions
    WHERE user_id = v_user_id
      AND created_at >= CURRENT_DATE
      AND price_paid = 0;

    IF v_used_boosts_today >= v_free_boosts THEN
      RETURN json_build_object('success', false, 'error', 'Бесплатные бусты на сегодня исчерпаны');
    END IF;

    v_price := 0;
    v_boost_type := CASE
      WHEN v_sub_duration >= 24 THEN 'top'
      WHEN v_sub_duration >= 6 THEN 'premium'
      ELSE 'standard'
    END;
    v_expires_at := now() + (v_sub_duration || ' hours')::INTERVAL;

    UPDATE public.track_promotions
    SET is_active = false
    WHERE track_id = p_track_id;

    INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
    VALUES (p_track_id, v_user_id, v_boost_type, 0, v_expires_at)
    RETURNING id INTO v_promotion_id;

    SELECT balance
    INTO v_user_balance
    FROM public.profiles
    WHERE user_id = v_user_id;

    INSERT INTO public.balance_transactions (
      user_id,
      amount,
      type,
      description,
      reference_id,
      reference_type,
      balance_before,
      balance_after,
      metadata
    ) VALUES (
      v_user_id,
      0,
      'purchase',
      'Бесплатный буст трека «' || COALESCE(v_track_title, '—') || '» на ' || v_sub_duration || ' ч.',
      v_promotion_id,
      'promotion',
      v_user_balance,
      v_user_balance,
      jsonb_build_object(
        'track_id', p_track_id,
        'track_title', v_track_title,
        'duration_hours', v_sub_duration,
        'expires_at', v_expires_at,
        'free_boost', true,
        'source', 'subscription'
      )
    );

    RETURN json_build_object(
      'success', true,
      'promotion_id', v_promotion_id,
      'expires_at', v_expires_at,
      'price', 0,
      'free_boost', true
    );
  END IF;

  CASE p_boost_duration_hours
    WHEN 1 THEN
      v_service_name := 'boost_track_1h';
      v_boost_type := 'standard';
    WHEN 6 THEN
      v_service_name := 'boost_track_6h';
      v_boost_type := 'premium';
    WHEN 24 THEN
      v_service_name := 'boost_track_24h';
      v_boost_type := 'top';
    ELSE
      RETURN json_build_object('success', false, 'error', 'Неверная длительность');
  END CASE;

  SELECT price_rub
  INTO v_price
  FROM public.addon_services
  WHERE name = v_service_name;

  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Услуга не найдена');
  END IF;

  SELECT balance
  INTO v_user_balance
  FROM public.profiles
  WHERE user_id = v_user_id
  FOR UPDATE;

  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_price
  WHERE user_id = v_user_id
  RETURNING balance INTO v_new_balance;

  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;

  UPDATE public.track_promotions
  SET is_active = false
  WHERE track_id = p_track_id;

  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    type,
    description,
    reference_id,
    reference_type,
    balance_before,
    balance_after,
    metadata
  ) VALUES (
    v_user_id,
    -v_price,
    'purchase',
    'Буст трека «' || COALESCE(v_track_title, '—') || '» на ' || p_boost_duration_hours || ' ч.',
    v_promotion_id,
    'promotion',
    v_user_balance,
    v_new_balance,
    jsonb_build_object(
      'track_id', p_track_id,
      'track_title', v_track_title,
      'duration_hours', p_boost_duration_hours,
      'expires_at', v_expires_at,
      'free_boost', false,
      'service_name', v_service_name
    )
  );

  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', v_price,
    'free_boost', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER DEFAULT 1
)
RETURNS JSON
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.purchase_track_boost(p_track_id, p_boost_duration_hours, false);
$$;

GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER) TO authenticated;
