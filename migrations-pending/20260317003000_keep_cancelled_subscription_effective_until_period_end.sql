-- Отменённая подписка должна сохранять тариф и привилегии до current_period_end

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
  SELECT us.*, sp.tier_key, sp.name_ru AS plan_name
  INTO v_sub
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  IF v_sub IS NULL THEN
    SELECT * INTO v_plan
    FROM public.subscription_plans
    WHERE tier_key = 'free' AND is_active = true
    LIMIT 1;

    IF v_plan IS NULL THEN
      RETURN jsonb_build_object(
        'tier_key', 'free',
        'plan_name', 'Базовый',
        'has_subscription', false,
        'is_cancelled', false
      );
    END IF;

    RETURN jsonb_build_object(
      'tier_key', 'free',
      'plan_name', v_plan.name_ru,
      'plan_id', v_plan.id,
      'has_subscription', false,
      'subscription_status', NULL,
      'is_cancelled', false,
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

  SELECT * INTO v_plan
  FROM public.subscription_plans
  WHERE id = v_sub.plan_id;

  RETURN jsonb_build_object(
    'tier_key', v_plan.tier_key,
    'plan_name', v_plan.name_ru,
    'plan_id', v_plan.id,
    'has_subscription', true,
    'subscription_id', v_sub.id,
    'subscription_status', v_sub.status,
    'is_cancelled', v_sub.status = 'canceled',
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

CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  track_id UUID,
  title TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration INTEGER,
  author_id UUID,
  author_username TEXT,
  author_avatar TEXT,
  author_tier TEXT,
  author_xp INTEGER,
  genre_name TEXT,
  chance_score NUMERIC,
  quality_component NUMERIC,
  xp_component NUMERIC,
  freshness_component NUMERIC,
  discovery_component NUMERIC,
  source TEXT,
  is_boosted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_w_quality NUMERIC := 0.35;
  v_w_xp NUMERIC := 0.25;
  v_w_stake NUMERIC := 0.20;
  v_w_freshness NUMERIC := 0.15;
  v_w_discovery NUMERIC := 0.05;
  v_min_quality NUMERIC := 2.0;
  v_min_duration INTEGER := 30;
  v_discovery_days INTEGER := 14;
  v_discovery_mult NUMERIC := 2.5;
BEGIN
  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS tid,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, 0)::INTEGER AS author_xp,
      g.name AS genre_name,
      GREATEST(v_min_quality, 1 + COALESCE(t.likes_count, 0) * 0.5 + COALESCE(t.plays_count, 0) * 0.02) AS q,
      LEAST(1.0, COALESCE(fus.xp_total, 0)::NUMERIC / 500.0) AS xp,
      CASE WHEN tp.id IS NOT NULL THEN 1.5 ELSE 0.5 END
        * COALESCE(sp.radio_weight_multiplier, 1.0) AS stake,
      1.0 / (1.0 + EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400.0 / 30.0) AS fresh,
      CASE WHEN p.created_at > now() - (v_discovery_days || ' days')::interval THEN v_discovery_mult ELSE 1.0 END AS disc,
      (tp.id IS NOT NULL) AS boosted
    FROM public.tracks t
    JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.track_promotions tp ON tp.track_id = t.id AND tp.status = 'active' AND (tp.expires_at > now() OR tp.ends_at > now())
    LEFT JOIN public.user_subscriptions us
      ON us.user_id = t.user_id
      AND us.status IN ('active', 'canceled')
      AND us.current_period_end > now()
    LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE t.status = 'completed'
      AND t.is_public = true
      AND t.audio_url IS NOT NULL
      AND (t.duration IS NULL OR t.duration >= v_min_duration)
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
  )
  SELECT
    s.tid,
    s.title,
    s.audio_url,
    s.cover_url,
    s.duration::INTEGER,
    s.author_id,
    s.author_username,
    s.author_avatar,
    s.author_tier,
    s.author_xp,
    s.genre_name,
    (s.q * v_w_quality + s.xp * v_w_xp + s.stake * v_w_stake + s.fresh * v_w_freshness + s.disc * v_w_discovery)::NUMERIC AS chance_score,
    s.q::NUMERIC AS quality_component,
    s.xp::NUMERIC AS xp_component,
    s.fresh::NUMERIC AS freshness_component,
    s.disc::NUMERIC AS discovery_component,
    'algorithm'::TEXT AS source,
    s.boosted
  FROM scored s
  ORDER BY (s.q * v_w_quality + s.xp * v_w_xp + s.stake * v_w_stake + s.fresh * v_w_freshness + s.disc * v_w_discovery) DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID,
  p_slot_id UUID,
  p_track_id UUID,
  p_amount INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot RECORD;
  v_min_bid INTEGER := 10;
  v_bid_step INTEGER := 5;
  v_highest INTEGER;
  v_balance INTEGER;
  v_discount_pct INTEGER := 0;
  v_effective_amount INTEGER;
BEGIN
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_found');
  END IF;
  IF v_slot.status NOT IN ('open', 'bidding') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  SELECT COALESCE(sp.radio_auction_discount_pct, 0) INTO v_discount_pct
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  v_effective_amount := GREATEST(1, (p_amount * (100 - v_discount_pct) / 100)::INTEGER);

  SELECT COALESCE(MAX(amount), 0) INTO v_highest FROM public.radio_bids WHERE slot_id = p_slot_id AND status = 'active';
  IF p_amount < v_min_bid OR p_amount < v_highest + v_bid_step THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_required', v_highest + v_bid_step);
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_effective_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.radio_bids SET status = 'outbid' WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active';

  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount) VALUES (p_slot_id, p_user_id, p_track_id, p_amount);
  UPDATE public.profiles SET balance = balance - v_effective_amount WHERE user_id = p_user_id;
  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1 WHERE id = p_slot_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'effective_cost', v_effective_amount, 'discount_pct', v_discount_pct, 'slot_id', p_slot_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.radio_place_bid(UUID, UUID, UUID, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER DEFAULT 1
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

  SELECT title, is_public INTO v_track_title, v_track_public
  FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id;

  IF v_track_title IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;

  IF NOT v_track_public THEN
    RETURN json_build_object('success', false, 'error', 'Трек должен быть публичным для продвижения в ленте');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.track_promotions
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
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

  IF v_free_boosts > 0 THEN
    SELECT COUNT(*) INTO v_used_boosts_today
    FROM public.track_promotions
    WHERE user_id = v_user_id
      AND created_at >= CURRENT_DATE
      AND price_paid = 0;
  END IF;

  IF v_free_boosts > 0 AND v_used_boosts_today < v_free_boosts THEN
    v_price := 0;
    v_boost_type := CASE WHEN v_sub_duration >= 24 THEN 'top' WHEN v_sub_duration >= 6 THEN 'premium' ELSE 'standard' END;
    v_expires_at := now() + (v_sub_duration || ' hours')::INTERVAL;

    UPDATE public.track_promotions SET is_active = false WHERE track_id = p_track_id;

    INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
    VALUES (p_track_id, v_user_id, v_boost_type, 0, v_expires_at)
    RETURNING id INTO v_promotion_id;

    RETURN json_build_object('success', true, 'promotion_id', v_promotion_id, 'expires_at', v_expires_at, 'price', 0, 'free_boost', true);
  END IF;

  CASE p_boost_duration_hours
    WHEN 1 THEN v_service_name := 'boost_track_1h'; v_boost_type := 'standard';
    WHEN 6 THEN v_service_name := 'boost_track_6h'; v_boost_type := 'premium';
    WHEN 24 THEN v_service_name := 'boost_track_24h'; v_boost_type := 'top';
    ELSE RETURN json_build_object('success', false, 'error', 'Неверная длительность');
  END CASE;

  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;
  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Услуга не найдена');
  END IF;

  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id FOR UPDATE;
  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
  END IF;

  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id
    RETURNING balance INTO v_new_balance;

  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;

  UPDATE public.track_promotions SET is_active = false WHERE track_id = p_track_id;

  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;

  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after
  ) VALUES (
    v_user_id, -v_price, 'purchase',
    'Буст трека «' || COALESCE(v_track_title, '—') || '» на ' || p_boost_duration_hours || ' ч.',
    v_promotion_id, 'promotion',
    v_user_balance, v_new_balance
  );

  RETURN json_build_object('success', true, 'promotion_id', v_promotion_id, 'expires_at', v_expires_at, 'price', v_price, 'free_boost', false);
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.check_deposit_limit(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_free_deposits INTEGER := 0;
  v_used_deposits INTEGER := 0;
BEGIN
  SELECT COALESCE(sp.deposits_free_monthly, 0) INTO v_free_deposits
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  SELECT COUNT(*) INTO v_used_deposits
  FROM public.track_deposits
  WHERE user_id = p_user_id
    AND created_at >= date_trunc('month', now());

  RETURN jsonb_build_object(
    'free_remaining', GREATEST(0, v_free_deposits - v_used_deposits),
    'free_total', v_free_deposits,
    'used_this_month', v_used_deposits,
    'is_free', v_used_deposits < v_free_deposits
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_deposit_limit(UUID) TO authenticated;

CREATE OR REPLACE VIEW public.moderation_queue_prioritized AS
SELECT
  t.id AS track_id,
  t.title,
  t.user_id,
  t.moderation_status,
  t.created_at AS submitted_at,
  COALESCE(sp.moderation_priority, 0) AS sub_priority,
  COALESCE(sp.moderation_sla_hours, 168) AS sla_hours,
  sp.tier_key AS author_tier
FROM public.tracks t
LEFT JOIN public.user_subscriptions us
  ON us.user_id = t.user_id
  AND us.status IN ('active', 'canceled')
  AND us.current_period_end > now()
LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
WHERE t.moderation_status = 'pending'
ORDER BY
  COALESCE(sp.moderation_priority, 0) DESC,
  t.created_at ASC;
