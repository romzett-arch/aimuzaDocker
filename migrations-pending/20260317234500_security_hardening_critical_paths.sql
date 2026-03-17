-- Critical path hardening:
-- 1. restore ownership checks in sensitive SECURITY DEFINER RPCs
-- 2. close private track leakage through share_token RLS
-- 3. require admin role inside get_l2e_admin_stats

DROP POLICY IF EXISTS "Anyone can view public tracks or shared tracks" ON public.tracks;
DROP POLICY IF EXISTS "Users can view own or public or shared tracks" ON public.tracks;

CREATE POLICY "Anyone can view public tracks"
ON public.tracks
FOR SELECT
TO anon
USING (
  is_public = true
  AND status = 'completed'
);

CREATE POLICY "Users can view own or public tracks"
ON public.tracks
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR (is_public = true AND status = 'completed')
);

CREATE OR REPLACE FUNCTION public.get_track_by_share_token(_token TEXT, _track_id UUID DEFAULT NULL)
RETURNS public.tracks
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.tracks
  WHERE share_token = _token
    AND status = 'completed'
    AND (_track_id IS NULL OR id = _track_id)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.purchase_ad_free(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_price INTEGER;
  v_duration_days INTEGER;
  v_user_balance INTEGER;
  v_new_balance INTEGER;
  v_new_ad_free_until TIMESTAMPTZ;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL OR v_caller <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden');
  END IF;

  SELECT value::integer INTO v_price FROM public.ad_settings WHERE key = 'ad_free_price';
  SELECT value::integer INTO v_duration_days FROM public.ad_settings WHERE key = 'ad_free_duration_days';

  v_price := COALESCE(v_price, 299);
  v_duration_days := COALESCE(v_duration_days, 30);

  SELECT balance INTO v_user_balance
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_user_balance IS NULL OR v_user_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств');
  END IF;

  UPDATE public.profiles
  SET
    balance = balance - v_price,
    ad_free_until = CASE
      WHEN ad_free_until IS NULL OR ad_free_until < now()
      THEN now() + (v_duration_days || ' days')::interval
      ELSE ad_free_until + (v_duration_days || ' days')::interval
    END,
    ad_free_purchased_at = now()
  WHERE user_id = p_user_id
  RETURNING balance, ad_free_until INTO v_new_balance, v_new_ad_free_until;

  INSERT INTO public.payments (user_id, amount, type, status, description)
  VALUES (p_user_id, v_price, 'ad_free', 'completed', 'Покупка опции "Без рекламы" на ' || v_duration_days || ' дней');

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    balance_before,
    balance_after,
    type,
    description,
    reference_type,
    metadata
  ) VALUES (
    p_user_id,
    -v_price,
    v_user_balance,
    v_new_balance,
    'addon_service',
    'Опция "Без рекламы" на ' || v_duration_days || ' дней',
    'ad_free',
    jsonb_build_object(
      'days', v_duration_days,
      'service', 'ad_free'
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'ad_free_until', v_new_ad_free_until,
    'price', v_price,
    'days', v_duration_days
  );
END;
$$;

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
  v_caller UUID;
  v_slot RECORD;
  v_min_bid INTEGER := 10;
  v_bid_step INTEGER := 5;
  v_highest INTEGER;
  v_balance INTEGER;
  v_discount_pct INTEGER := 0;
  v_effective_amount INTEGER;
  v_old_bid RECORD;
  v_new_bid_id UUID;
  v_balance_after_refund INTEGER;
  v_balance_after_debit INTEGER;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL OR v_caller <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT * INTO v_slot
  FROM public.radio_slots
  WHERE id = p_slot_id;

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

  SELECT COALESCE(MAX(amount), 0) INTO v_highest
  FROM public.radio_bids
  WHERE slot_id = p_slot_id
    AND status = 'active';

  IF p_amount < v_min_bid OR p_amount < v_highest + v_bid_step THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_required', GREATEST(v_min_bid, v_highest + v_bid_step));
  END IF;

  SELECT
    id,
    amount,
    COALESCE(charged_amount, amount) AS charged_amount
  INTO v_old_bid
  FROM public.radio_bids
  WHERE slot_id = p_slot_id
    AND user_id = p_user_id
    AND status = 'active'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_old_bid.id IS NOT NULL THEN
    UPDATE public.profiles
    SET balance = balance + v_old_bid.charged_amount
    WHERE user_id = p_user_id
    RETURNING balance INTO v_balance_after_refund;

    INSERT INTO public.balance_transactions (
      user_id,
      amount,
      balance_before,
      balance_after,
      type,
      description,
      reference_id,
      reference_type
    ) VALUES (
      p_user_id,
      v_old_bid.charged_amount,
      v_balance_after_refund - v_old_bid.charged_amount,
      v_balance_after_refund,
      'refund',
      'Возврат предыдущей ставки на слот #' || v_slot.slot_number,
      v_old_bid.id,
      'radio_bid'
    );

    UPDATE public.radio_bids
    SET status = 'outbid'
    WHERE id = v_old_bid.id;
  END IF;

  SELECT balance INTO v_balance
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_balance IS NULL OR v_balance < v_effective_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_effective_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_balance_after_debit;

  INSERT INTO public.radio_bids (
    slot_id,
    user_id,
    track_id,
    amount,
    charged_amount
  ) VALUES (
    p_slot_id,
    p_user_id,
    p_track_id,
    p_amount,
    v_effective_amount
  )
  RETURNING id INTO v_new_bid_id;

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    balance_before,
    balance_after,
    type,
    description,
    reference_id,
    reference_type,
    metadata
  ) VALUES (
    p_user_id,
    -v_effective_amount,
    v_balance_after_debit + v_effective_amount,
    v_balance_after_debit,
    'debit',
    'Ставка ' || p_amount || '₽ на слот #' || v_slot.slot_number,
    v_new_bid_id,
    'radio_bid',
    jsonb_build_object(
      'slot_id', p_slot_id,
      'track_id', p_track_id,
      'bid_amount', p_amount,
      'effective_cost', v_effective_amount,
      'discount_pct', v_discount_pct
    )
  );

  UPDATE public.radio_slots
  SET status = 'bidding',
      total_bids = total_bids + 1
  WHERE id = p_slot_id;

  RETURN jsonb_build_object(
    'ok', true,
    'bid_amount', p_amount,
    'effective_cost', v_effective_amount,
    'discount_pct', v_discount_pct,
    'slot_id', p_slot_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_l2e_admin_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_xp_today BIGINT := 0;
  v_listens_today BIGINT := 0;
  v_afk_verified_today BIGINT := 0;
  v_unique_listeners BIGINT := 0;
  v_active_sessions BIGINT := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listens') THEN
    SELECT COALESCE(SUM(xp_earned), 0) INTO v_xp_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COUNT(*) INTO v_listens_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COUNT(*) INTO v_afk_verified_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE AND is_afk_verified = true;
    SELECT COUNT(DISTINCT user_id) INTO v_unique_listeners
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listeners') THEN
    SELECT COUNT(*) INTO v_active_sessions
    FROM public.radio_listeners WHERE last_heartbeat > NOW() - INTERVAL '2 minutes';
  END IF;

  SELECT jsonb_build_object(
    'xp_awarded_today', v_xp_today,
    'listens_today', v_listens_today,
    'afk_verified_today', v_afk_verified_today,
    'unique_listeners_today', v_unique_listeners,
    'active_sessions_now', v_active_sessions,
    'avg_xp_per_listener', CASE WHEN v_unique_listeners > 0 THEN ROUND(v_xp_today::NUMERIC / v_unique_listeners, 1) ELSE 0 END
  ) INTO v_result;

  RETURN v_result;
END;
$$;
