-- ============================================================
-- PREMIUM SUBSCRIPTIONS — Фаза 2: RPC-функции
-- get_user_subscription_tier, subscribe_to_plan,
-- cancel_subscription_with_refund, check_track_upload_limit,
-- record_track_upload, renew_expired_subscriptions
-- ============================================================

-- ─── 1. get_user_subscription_tier ─────────────────────────
-- Возвращает текущий тир пользователя + все привилегии плана

CREATE OR REPLACE FUNCTION public.get_user_subscription_tier(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub RECORD;
  v_plan RECORD;
BEGIN
  -- Найти активную подписку
  SELECT us.*, sp.tier_key, sp.name_ru AS plan_name
  INTO v_sub
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status = 'active'
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  -- Если нет активной подписки — возвращаем FREE план
  IF v_sub IS NULL THEN
    SELECT * INTO v_plan
    FROM public.subscription_plans
    WHERE tier_key = 'free' AND is_active = true
    LIMIT 1;

    IF v_plan IS NULL THEN
      RETURN jsonb_build_object('tier_key', 'free', 'plan_name', 'Новичок', 'has_subscription', false);
    END IF;

    RETURN jsonb_build_object(
      'tier_key', 'free',
      'plan_name', v_plan.name_ru,
      'plan_id', v_plan.id,
      'has_subscription', false,
      'tracks_free_monthly', v_plan.tracks_free_monthly,
      'tracks_free_daily', v_plan.tracks_free_daily,
      'tracks_monthly_hard_limit', v_plan.tracks_monthly_hard_limit,
      'extra_track_price', v_plan.extra_track_price,
      'free_track_pricing', COALESCE(v_plan.free_track_pricing, '[]'::jsonb),
      'boosts_per_day', v_plan.boosts_per_day,
      'boost_duration_hours', v_plan.boost_duration_hours,
      'deposits_free_monthly', v_plan.deposits_free_monthly,
      'radio_weight_multiplier', v_plan.radio_weight_multiplier,
      'radio_guaranteed_slots_weekly', v_plan.radio_guaranteed_slots_weekly,
      'radio_auction_discount_pct', v_plan.radio_auction_discount_pct,
      'radio_stats_enabled', v_plan.radio_stats_enabled,
      'radio_stats_extended', v_plan.radio_stats_extended,
      'radio_api_access', v_plan.radio_api_access,
      'ad_free', v_plan.ad_free,
      'moderation_priority', v_plan.moderation_priority,
      'moderation_sla_hours', v_plan.moderation_sla_hours,
      'can_sell_marketplace', v_plan.can_sell_marketplace,
      'can_participate_contests', v_plan.can_participate_contests,
      'contest_priority', v_plan.contest_priority,
      'badge_emoji', v_plan.badge_emoji
    );
  END IF;

  -- Есть активная подписка — возвращаем данные плана
  SELECT * INTO v_plan
  FROM public.subscription_plans
  WHERE id = v_sub.plan_id;

  RETURN jsonb_build_object(
    'tier_key', v_plan.tier_key,
    'plan_name', v_plan.name_ru,
    'plan_id', v_plan.id,
    'has_subscription', true,
    'subscription_id', v_sub.id,
    'period_type', v_sub.period_type,
    'current_period_end', v_sub.current_period_end,
    'auto_renew', v_sub.auto_renew,
    'tracks_free_monthly', v_plan.tracks_free_monthly,
    'tracks_free_daily', v_plan.tracks_free_daily,
    'tracks_monthly_hard_limit', v_plan.tracks_monthly_hard_limit,
    'extra_track_price', v_plan.extra_track_price,
    'free_track_pricing', COALESCE(v_plan.free_track_pricing, '[]'::jsonb),
    'boosts_per_day', v_plan.boosts_per_day,
    'boost_duration_hours', v_plan.boost_duration_hours,
    'deposits_free_monthly', v_plan.deposits_free_monthly,
    'radio_weight_multiplier', v_plan.radio_weight_multiplier,
    'radio_guaranteed_slots_weekly', v_plan.radio_guaranteed_slots_weekly,
    'radio_auction_discount_pct', v_plan.radio_auction_discount_pct,
    'radio_stats_enabled', v_plan.radio_stats_enabled,
    'radio_stats_extended', v_plan.radio_stats_extended,
    'radio_api_access', v_plan.radio_api_access,
    'ad_free', v_plan.ad_free,
    'moderation_priority', v_plan.moderation_priority,
    'moderation_sla_hours', v_plan.moderation_sla_hours,
    'can_sell_marketplace', v_plan.can_sell_marketplace,
    'can_participate_contests', v_plan.can_participate_contests,
    'contest_priority', v_plan.contest_priority,
    'badge_emoji', v_plan.badge_emoji
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_subscription_tier(UUID) TO authenticated;


-- ─── 2. subscribe_to_plan ──────────────────────────────────
-- Оформление/апгрейд подписки. Списание с баланса. Prorated refund при апгрейде.

CREATE OR REPLACE FUNCTION public.subscribe_to_plan(
  p_user_id UUID,
  p_plan_id UUID,
  p_period_type TEXT DEFAULT 'monthly'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_plan RECORD;
  v_current_sub RECORD;
  v_price INTEGER;
  v_balance INTEGER;
  v_new_balance INTEGER;
  v_refund INTEGER := 0;
  v_period_end TIMESTAMPTZ;
  v_new_sub_id UUID;
  v_days_remaining INTEGER;
  v_total_days INTEGER;
BEGIN
  -- Авторизация
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR (v_caller != p_user_id AND NOT public.is_admin(v_caller)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  -- Валидация period_type
  IF p_period_type NOT IN ('monthly', 'yearly') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_period_type');
  END IF;

  -- Получить план
  SELECT * INTO v_plan FROM public.subscription_plans WHERE id = p_plan_id AND is_active = true;
  IF v_plan IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'plan_not_found');
  END IF;

  -- Нельзя подписаться на FREE
  IF v_plan.tier_key = 'free' THEN
    RETURN jsonb_build_object('success', false, 'error', 'cannot_subscribe_to_free');
  END IF;

  -- Определить цену
  v_price := CASE WHEN p_period_type = 'yearly' THEN v_plan.price_yearly ELSE v_plan.price_monthly END;

  -- Проверить текущую подписку
  SELECT us.*, sp.price_monthly AS current_price_monthly, sp.price_yearly AS current_price_yearly, sp.tier_key AS current_tier
  INTO v_current_sub
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status = 'active'
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  -- Prorated refund при апгрейде
  IF v_current_sub IS NOT NULL THEN
    -- Нельзя подписаться на тот же план
    IF v_current_sub.plan_id = p_plan_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'already_subscribed_to_this_plan');
    END IF;

    -- Рассчитать возврат: (оставшиеся дни / общие дни) × оплаченная цена
    v_days_remaining := GREATEST(0, EXTRACT(DAY FROM (v_current_sub.current_period_end - now()))::INTEGER);
    v_total_days := CASE WHEN v_current_sub.period_type = 'yearly' THEN 365 ELSE 30 END;
    v_refund := GREATEST(0, (
      v_days_remaining::NUMERIC / v_total_days *
      CASE WHEN v_current_sub.period_type = 'yearly' THEN v_current_sub.current_price_yearly ELSE v_current_sub.current_price_monthly END
    )::INTEGER);

    -- Деактивировать текущую подписку
    UPDATE public.user_subscriptions
      SET status = 'replaced', canceled_at = now()
      WHERE id = v_current_sub.id;

    -- Зачислить возврат
    IF v_refund > 0 THEN
      UPDATE public.profiles SET balance = balance + v_refund WHERE user_id = p_user_id;

      INSERT INTO public.balance_transactions
        (user_id, amount, type, description, balance_before, balance_after)
      SELECT p_user_id, v_refund, 'refund',
        'Возврат за подписку ' || v_current_sub.current_tier || ' (' || v_days_remaining || ' дн.)',
        balance - v_refund, balance
      FROM public.profiles WHERE user_id = p_user_id;

      INSERT INTO public.subscription_events
        (user_id, subscription_id, event_type, plan_id, amount, metadata)
      VALUES
        (p_user_id, v_current_sub.id, 'refunded', v_current_sub.plan_id, v_refund,
         jsonb_build_object('days_remaining', v_days_remaining, 'total_days', v_total_days));
    END IF;
  END IF;

  -- Итоговая цена с учётом возврата
  v_price := GREATEST(0, v_price - v_refund);

  -- Проверить баланс
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'profile_not_found');
  END IF;

  IF v_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'required', v_price, 'balance', v_balance, 'refund', v_refund);
  END IF;

  -- Списать с баланса
  IF v_price > 0 THEN
    UPDATE public.profiles SET balance = balance - v_price WHERE user_id = p_user_id
      RETURNING balance INTO v_new_balance;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (p_user_id, -v_price, 'purchase',
       'Подписка ' || v_plan.name_ru || ' (' || p_period_type || ')',
       v_new_balance + v_price, v_new_balance);
  ELSE
    SELECT balance INTO v_new_balance FROM public.profiles WHERE user_id = p_user_id;
  END IF;

  -- Рассчитать конец периода
  IF p_period_type = 'yearly' THEN
    v_period_end := now() + INTERVAL '1 year';
  ELSE
    v_period_end := now() + INTERVAL '1 month';
  END IF;

  -- Создать подписку
  INSERT INTO public.user_subscriptions
    (user_id, plan_id, status, period_type, current_period_start, current_period_end, auto_renew)
  VALUES
    (p_user_id, p_plan_id, 'active', p_period_type, now(), v_period_end, true)
  RETURNING id INTO v_new_sub_id;

  -- Лог события
  INSERT INTO public.subscription_events
    (user_id, subscription_id, event_type, plan_id, amount, metadata)
  VALUES
    (p_user_id, v_new_sub_id,
     CASE WHEN v_current_sub IS NOT NULL THEN 'upgraded' ELSE 'created' END,
     p_plan_id, v_price,
     jsonb_build_object('period_type', p_period_type, 'refund', v_refund, 'price_paid', v_price));

  -- Если план ad_free — обновить profiles.ad_free_until
  IF v_plan.ad_free THEN
    UPDATE public.profiles
      SET ad_free_until = GREATEST(COALESCE(ad_free_until, now()), v_period_end)
      WHERE user_id = p_user_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'subscription_id', v_new_sub_id,
    'plan_id', p_plan_id,
    'tier_key', v_plan.tier_key,
    'period_end', v_period_end,
    'price_paid', v_price,
    'refund', v_refund,
    'new_balance', v_new_balance
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.subscribe_to_plan(UUID, UUID, TEXT) TO authenticated;


-- ─── 3. cancel_subscription_with_refund ────────────────────

CREATE OR REPLACE FUNCTION public.cancel_subscription_with_refund(
  p_subscription_id UUID,
  p_refund BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_sub RECORD;
  v_plan RECORD;
  v_refund_amount INTEGER := 0;
  v_days_remaining INTEGER;
  v_total_days INTEGER;
  v_paid_price INTEGER;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;

  SELECT us.*, sp.tier_key, sp.price_monthly, sp.price_yearly
  INTO v_sub
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.id = p_subscription_id
    AND us.status = 'active';

  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'subscription_not_found');
  END IF;

  IF v_caller IS NULL OR (v_caller != v_sub.user_id AND NOT public.is_admin(v_caller)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  -- Рассчитать prorated refund
  IF p_refund THEN
    v_days_remaining := GREATEST(0, EXTRACT(DAY FROM (v_sub.current_period_end - now()))::INTEGER);
    v_total_days := CASE WHEN v_sub.period_type = 'yearly' THEN 365 ELSE 30 END;
    v_paid_price := CASE WHEN v_sub.period_type = 'yearly' THEN v_sub.price_yearly ELSE v_sub.price_monthly END;
    v_refund_amount := GREATEST(0, (v_days_remaining::NUMERIC / v_total_days * v_paid_price)::INTEGER);

    IF v_refund_amount > 0 THEN
      UPDATE public.profiles SET balance = balance + v_refund_amount WHERE user_id = v_sub.user_id;

      INSERT INTO public.balance_transactions
        (user_id, amount, type, description, balance_before, balance_after)
      SELECT v_sub.user_id, v_refund_amount, 'refund',
        'Возврат за отмену подписки ' || v_sub.tier_key || ' (' || v_days_remaining || ' дн.)',
        balance - v_refund_amount, balance
      FROM public.profiles WHERE user_id = v_sub.user_id;
    END IF;
  END IF;

  -- Отменить подписку (действует до конца периода)
  UPDATE public.user_subscriptions
    SET status = 'canceled', canceled_at = now(), auto_renew = false
    WHERE id = p_subscription_id;

  -- Лог
  INSERT INTO public.subscription_events
    (user_id, subscription_id, event_type, plan_id, amount, metadata)
  VALUES
    (v_sub.user_id, p_subscription_id, 'canceled', v_sub.plan_id, v_refund_amount,
     jsonb_build_object('refund', v_refund_amount, 'days_remaining', COALESCE(v_days_remaining, 0)));

  RETURN jsonb_build_object(
    'success', true,
    'refund_amount', v_refund_amount,
    'active_until', v_sub.current_period_end
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_subscription_with_refund(UUID, BOOLEAN) TO authenticated;


-- ─── 4. check_track_upload_limit ───────────────────────────

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
  v_can_upload BOOLEAN := true;
  v_is_free_tier BOOLEAN;
  v_nth INTEGER;
  v_item JSONB;
BEGIN
  -- Получить тир
  v_tier := public.get_user_subscription_tier(p_user_id);
  v_is_free_tier := (v_tier->>'tier_key') = 'free';

  v_daily_limit := (v_tier->>'tracks_free_daily')::INTEGER;
  v_monthly_free := (v_tier->>'tracks_free_monthly')::INTEGER;
  v_monthly_hard_limit := (v_tier->>'tracks_monthly_hard_limit')::INTEGER;
  v_extra_price := (v_tier->>'extra_track_price')::INTEGER;
  v_pricing := v_tier->'free_track_pricing';

  -- Подсчёт загрузок
  SELECT COUNT(*) INTO v_daily_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id AND upload_date = CURRENT_DATE;

  SELECT COUNT(*) INTO v_monthly_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND upload_date >= date_trunc('month', CURRENT_DATE)::DATE;

  -- Жёсткий месячный лимит (только FREE)
  IF v_monthly_hard_limit > 0 AND v_monthly_count >= v_monthly_hard_limit THEN
    RETURN jsonb_build_object(
      'can_upload', false, 'price', 0,
      'daily_count', v_daily_count, 'monthly_count', v_monthly_count,
      'daily_limit', v_daily_limit, 'monthly_free', v_monthly_free,
      'monthly_hard_limit', v_monthly_hard_limit,
      'reason', 'monthly_limit_reached',
      'tier_key', v_tier->>'tier_key'
    );
  END IF;

  -- FREE: прогрессивная цена по порядку загрузки в день
  IF v_is_free_tier AND v_pricing IS NOT NULL AND jsonb_array_length(v_pricing) > 0 THEN
    -- Дневной лимит
    IF v_daily_limit > 0 AND v_daily_count >= v_daily_limit THEN
      RETURN jsonb_build_object(
        'can_upload', false, 'price', 0,
        'daily_count', v_daily_count, 'monthly_count', v_monthly_count,
        'daily_limit', v_daily_limit, 'monthly_free', v_monthly_free,
        'monthly_hard_limit', v_monthly_hard_limit,
        'reason', 'daily_limit_reached',
        'tier_key', v_tier->>'tier_key'
      );
    END IF;

    v_nth := v_daily_count + 1;
    -- Найти цену для n-го трека
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_pricing)
    LOOP
      IF (v_item->>'nth')::INTEGER = v_nth THEN
        v_price := (v_item->>'price')::INTEGER;
        EXIT;
      END IF;
    END LOOP;
    -- Если nth превышает массив — берём последнюю цену
    IF v_price = 0 AND v_nth > 1 THEN
      v_price := (v_pricing->(jsonb_array_length(v_pricing) - 1)->>'price')::INTEGER;
    END IF;
  ELSE
    -- Платные планы: сверх лимита = extra_track_price
    IF v_monthly_count >= v_monthly_free AND v_monthly_free > 0 THEN
      v_price := v_extra_price;
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
    'tier_key', v_tier->>'tier_key'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_track_upload_limit(UUID) TO authenticated;


-- ─── 5. record_track_upload ────────────────────────────────

CREATE OR REPLACE FUNCTION public.record_track_upload(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit JSONB;
  v_price INTEGER;
  v_new_balance INTEGER;
BEGIN
  -- Проверить лимит
  v_limit := public.check_track_upload_limit(p_user_id);

  IF NOT (v_limit->>'can_upload')::BOOLEAN THEN
    RETURN jsonb_build_object('success', false, 'error', v_limit->>'reason', 'limit', v_limit);
  END IF;

  v_price := (v_limit->>'price')::INTEGER;

  -- Списать если платно
  IF v_price > 0 THEN
    UPDATE public.profiles
      SET balance = balance - v_price
      WHERE user_id = p_user_id AND balance >= v_price
      RETURNING balance INTO v_new_balance;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'required', v_price);
    END IF;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (p_user_id, -v_price, 'purchase',
       'Загрузка трека (сверх лимита)',
       v_new_balance + v_price, v_new_balance);
  END IF;

  -- Записать загрузку
  INSERT INTO public.user_track_uploads (user_id, track_id, price_charged, is_free)
  VALUES (p_user_id, p_track_id, v_price, v_price = 0);

  RETURN jsonb_build_object(
    'success', true,
    'price_charged', v_price,
    'is_free', v_price = 0,
    'daily_count', (v_limit->>'daily_count')::INTEGER + 1,
    'monthly_count', (v_limit->>'monthly_count')::INTEGER + 1
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_track_upload(UUID, UUID) TO authenticated;


-- ─── 6. renew_expired_subscriptions ────────────────────────
-- Cron-функция: автопродление подписок с баланса

CREATE OR REPLACE FUNCTION public.renew_expired_subscriptions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec RECORD;
  v_plan RECORD;
  v_price INTEGER;
  v_balance INTEGER;
  v_new_balance INTEGER;
  v_period_end TIMESTAMPTZ;
  v_renewed INTEGER := 0;
  v_past_due INTEGER := 0;
  v_expired INTEGER := 0;
BEGIN
  -- 1. Автопродление: active + auto_renew + период истёк
  FOR v_rec IN
    SELECT us.*, sp.price_monthly, sp.price_yearly, sp.tier_key, sp.ad_free, sp.name_ru
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.status = 'active'
      AND us.auto_renew = true
      AND us.current_period_end <= now()
  LOOP
    v_price := CASE WHEN v_rec.period_type = 'yearly' THEN v_rec.price_yearly ELSE v_rec.price_monthly END;

    SELECT balance INTO v_balance FROM public.profiles WHERE user_id = v_rec.user_id FOR UPDATE;

    IF v_balance >= v_price THEN
      -- Списать и продлить
      UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_rec.user_id
        RETURNING balance INTO v_new_balance;

      v_period_end := CASE WHEN v_rec.period_type = 'yearly'
        THEN v_rec.current_period_end + INTERVAL '1 year'
        ELSE v_rec.current_period_end + INTERVAL '1 month'
      END;

      UPDATE public.user_subscriptions
        SET current_period_start = v_rec.current_period_end,
            current_period_end = v_period_end
        WHERE id = v_rec.id;

      INSERT INTO public.balance_transactions
        (user_id, amount, type, description, balance_before, balance_after)
      VALUES
        (v_rec.user_id, -v_price, 'purchase',
         'Автопродление подписки ' || v_rec.name_ru,
         v_new_balance + v_price, v_new_balance);

      INSERT INTO public.subscription_events
        (user_id, subscription_id, event_type, plan_id, amount)
      VALUES (v_rec.user_id, v_rec.id, 'renewed', v_rec.plan_id, v_price);

      -- Обновить ad_free_until
      IF v_rec.ad_free THEN
        UPDATE public.profiles
          SET ad_free_until = GREATEST(COALESCE(ad_free_until, now()), v_period_end)
          WHERE user_id = v_rec.user_id;
      END IF;

      v_renewed := v_renewed + 1;
    ELSE
      -- Недостаточно средств — past_due
      UPDATE public.user_subscriptions SET status = 'past_due' WHERE id = v_rec.id;

      INSERT INTO public.subscription_events
        (user_id, subscription_id, event_type, plan_id, metadata)
      VALUES (v_rec.user_id, v_rec.id, 'past_due', v_rec.plan_id,
        jsonb_build_object('balance', v_balance, 'required', v_price));

      v_past_due := v_past_due + 1;
    END IF;
  END LOOP;

  -- 2. Экспирация: past_due > 3 дней
  FOR v_rec IN
    SELECT us.*
    FROM public.user_subscriptions us
    WHERE us.status = 'past_due'
      AND us.current_period_end <= now() - INTERVAL '3 days'
  LOOP
    UPDATE public.user_subscriptions SET status = 'expired' WHERE id = v_rec.id;

    INSERT INTO public.subscription_events
      (user_id, subscription_id, event_type, plan_id)
    VALUES (v_rec.user_id, v_rec.id, 'expired', v_rec.plan_id);

    v_expired := v_expired + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'renewed', v_renewed,
    'past_due', v_past_due,
    'expired', v_expired
  );
END;
$$;

-- Только service role может вызывать cron-функцию
GRANT EXECUTE ON FUNCTION public.renew_expired_subscriptions() TO authenticated;
