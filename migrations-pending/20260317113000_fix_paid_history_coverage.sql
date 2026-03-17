-- Fix: восстановить историю операций и корректное списание
-- 1) purchase_ad_free пишет balance_transactions
-- 2) radio_place_bid хранит фактическую сумму списания и рефандит предыдущую активную ставку пользователя

ALTER TABLE public.radio_bids
ADD COLUMN IF NOT EXISTS charged_amount INTEGER;

CREATE OR REPLACE FUNCTION public.purchase_ad_free(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price INTEGER;
  v_duration_days INTEGER;
  v_user_balance INTEGER;
  v_new_balance INTEGER;
  v_new_ad_free_until TIMESTAMPTZ;
BEGIN
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

GRANT EXECUTE ON FUNCTION public.radio_place_bid(UUID, UUID, UUID, INTEGER) TO authenticated;
