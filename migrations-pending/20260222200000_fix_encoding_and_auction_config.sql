-- Fix encoding: пересоздание функций с корректной UTF-8 кириллицей
-- Fix data: восстановление повреждённых записей в balance_transactions и notifications
-- Config: убрать commission_percent, добавить enabled в auction config

SET client_encoding = 'UTF8';

-- ============================================================
-- 1. Пересоздание radio_place_bid (без commission, с UTF-8)
-- ============================================================

DROP FUNCTION IF EXISTS public.radio_place_bid(uuid, uuid, uuid, integer);

CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID,
  p_slot_id UUID,
  p_track_id UUID,
  p_amount INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_slot RECORD;
  v_config JSONB;
  v_min_bid INTEGER;
  v_bid_step INTEGER;
  v_highest INTEGER;
  v_balance INTEGER;
  v_old_bid RECORD;
  v_new_bid_id UUID;
  v_track_title TEXT;
BEGIN
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_found');
  END IF;
  IF v_slot.status NOT IN ('open', 'bidding') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  -- Читаем настройки из radio_config
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'auction';
  v_min_bid  := COALESCE((v_config ->> 'min_bid_rub')::int,  10);
  v_bid_step := COALESCE((v_config ->> 'bid_step_rub')::int, 5);

  -- Проверяем, что аукцион включён
  IF COALESCE((v_config ->> 'enabled')::boolean, true) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', 'auction_disabled');
  END IF;

  SELECT COALESCE(MAX(amount), 0) INTO v_highest
    FROM public.radio_bids WHERE slot_id = p_slot_id AND status = 'active';

  IF p_amount < v_min_bid OR (v_highest > 0 AND p_amount < v_highest + v_bid_step) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low',
      'min_required', GREATEST(v_min_bid, v_highest + v_bid_step));
  END IF;

  -- Старая ставка этого пользователя
  SELECT id, amount INTO v_old_bid
    FROM public.radio_bids
    WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active'
    ORDER BY amount DESC LIMIT 1;

  -- Рефанд старой ставки
  IF v_old_bid.id IS NOT NULL THEN
    UPDATE public.profiles SET balance = balance + v_old_bid.amount WHERE user_id = p_user_id;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT p_user_id, v_old_bid.amount, 'refund',
           E'\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u043f\u0440\u0435\u0434\u044b\u0434\u0443\u0449\u0435\u0439 \u0441\u0442\u0430\u0432\u043a\u0438 \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number,
           'radio_bid', v_old_bid.id,
           balance - v_old_bid.amount, balance
    FROM public.profiles WHERE user_id = p_user_id;

    UPDATE public.radio_bids SET status = 'outbid' WHERE id = v_old_bid.id;
  END IF;

  -- Баланс
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Списание
  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  SELECT p_user_id, -p_amount, 'debit',
         E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || p_amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number,
         'radio_slot', p_slot_id,
         balance + p_amount, balance
  FROM public.profiles WHERE user_id = p_user_id;

  -- Ставка
  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount)
  VALUES (p_slot_id, p_user_id, p_track_id, p_amount)
  RETURNING id INTO v_new_bid_id;

  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1 WHERE id = p_slot_id;

  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id;

  -- Уведомление: ставка принята
  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  VALUES (
    p_user_id,
    'radio_bid_placed',
    E'\u0421\u0442\u0430\u0432\u043a\u0430 \u043f\u0440\u0438\u043d\u044f\u0442\u0430',
    E'\u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || p_amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number
      || E' (\u0442\u0440\u0435\u043a: ' || COALESCE(v_track_title, E'\u2014') || ')',
    jsonb_build_object('slot_id', p_slot_id, 'bid_id', v_new_bid_id, 'amount', p_amount, 'track_id', p_track_id),
    '/radio'
  );

  -- Уведомить перебитых
  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  SELECT
    rb.user_id,
    'radio_bid_outbid',
    E'\u0412\u0430\u0448\u0443 \u0441\u0442\u0430\u0432\u043a\u0443 \u043f\u0435\u0440\u0435\u0431\u0438\u043b\u0438!',
    E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || rb.amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number
      || E' \u043f\u0435\u0440\u0435\u0431\u0438\u0442\u0430 (' || p_amount || E'\u20bd). \u041f\u043e\u0434\u043d\u0438\u043c\u0438\u0442\u0435 \u0441\u0442\u0430\u0432\u043a\u0443!',
    jsonb_build_object('slot_id', p_slot_id, 'your_amount', rb.amount, 'new_highest', p_amount),
    '/radio'
  FROM public.radio_bids rb
  WHERE rb.slot_id = p_slot_id
    AND rb.status = 'active'
    AND rb.user_id != p_user_id
    AND rb.amount < p_amount;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$fn$;

-- ============================================================
-- 2. Пересоздание radio_refund_losers (UTF-8)
-- ============================================================

CREATE OR REPLACE FUNCTION public.radio_refund_losers(p_slot_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_slot RECORD;
  v_bid RECORD;
  v_refund_count INTEGER := 0;
BEGIN
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN RETURN 0; END IF;

  FOR v_bid IN
    SELECT rb.id, rb.user_id, rb.amount, rb.track_id
    FROM public.radio_bids rb
    WHERE rb.slot_id = p_slot_id
      AND rb.status = 'active'
      AND rb.user_id != COALESCE(v_slot.winner_user_id, '00000000-0000-0000-0000-000000000000'::uuid)
  LOOP
    UPDATE public.profiles SET balance = balance + v_bid.amount WHERE user_id = v_bid.user_id;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT v_bid.user_id, v_bid.amount, 'refund',
           E'\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u0441\u0442\u0430\u0432\u043a\u0438: \u0441\u043b\u043e\u0442 #' || v_slot.slot_number || E' \u0437\u0430\u0432\u0435\u0440\u0448\u0451\u043d',
           'radio_bid', v_bid.id,
           balance - v_bid.amount, balance
    FROM public.profiles WHERE user_id = v_bid.user_id;

    UPDATE public.radio_bids SET status = 'refunded' WHERE id = v_bid.id;

    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_bid.user_id,
      'radio_bid_refunded',
      E'\u0421\u0442\u0430\u0432\u043a\u0430 \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430',
      E'\u0421\u043b\u043e\u0442 #' || v_slot.slot_number || E' \u0437\u0430\u0432\u0435\u0440\u0448\u0451\u043d. \u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || v_bid.amount || E'\u20bd \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430 \u043d\u0430 \u0431\u0430\u043b\u0430\u043d\u0441.',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_bid.amount, 'refund', true),
      '/radio'
    );

    v_refund_count := v_refund_count + 1;
  END LOOP;

  IF v_slot.winner_user_id IS NOT NULL THEN
    UPDATE public.radio_bids SET status = 'won'
    WHERE slot_id = p_slot_id AND user_id = v_slot.winner_user_id AND status = 'active';

    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_slot.winner_user_id,
      'radio_bid_won',
      E'\u0412\u044b \u0432\u044b\u0438\u0433\u0440\u0430\u043b\u0438 \u0430\u0443\u043a\u0446\u0438\u043e\u043d!',
      E'\u0412\u0430\u0448 \u0442\u0440\u0435\u043a \u043f\u043e\u043f\u0430\u0434\u0451\u0442 \u0432 \u044d\u0444\u0438\u0440 \u0440\u0430\u0434\u0438\u043e (\u0441\u043b\u043e\u0442 #' || v_slot.slot_number || E', \u0441\u0442\u0430\u0432\u043a\u0430 ' || v_slot.winning_bid || E'\u20bd)!',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_slot.winning_bid, 'track_id', v_slot.winner_track_id),
      '/radio'
    );
  END IF;

  RETURN v_refund_count;
END;
$fn$;

-- ============================================================
-- 3. Пересоздание radio_create_next_slot (без изменений, но для консистентности)
-- ============================================================

CREATE OR REPLACE FUNCTION public.radio_create_next_slot()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_max_slot INTEGER;
  v_open_count INTEGER;
  v_new_id UUID;
BEGIN
  SELECT COUNT(*) INTO v_open_count FROM public.radio_slots WHERE status IN ('open', 'bidding');
  IF v_open_count >= 2 THEN RETURN NULL; END IF;

  SELECT COALESCE(MAX(slot_number), 0) INTO v_max_slot FROM public.radio_slots;

  INSERT INTO public.radio_slots (slot_number, starts_at, ends_at, status)
  VALUES (v_max_slot + 1, NOW(), NOW() + INTERVAL '1 hour', 'open')
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.radio_place_bid(uuid, uuid, uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.radio_refund_losers(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.radio_create_next_slot() TO service_role;

-- ============================================================
-- 4. Починка повреждённых записей в balance_transactions
-- ============================================================

UPDATE public.balance_transactions bt
SET description = E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || abs(bt.amount) || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || rs.slot_number
FROM public.radio_slots rs
WHERE bt.reference_type = 'radio_slot'
  AND bt.type = 'debit'
  AND bt.reference_id = rs.id
  AND bt.description ~ '^\?';

UPDATE public.balance_transactions bt
SET description = E'\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u043f\u0440\u0435\u0434\u044b\u0434\u0443\u0449\u0435\u0439 \u0441\u0442\u0430\u0432\u043a\u0438 \u043d\u0430 \u0441\u043b\u043e\u0442 #' || rs.slot_number
FROM public.radio_bids rb
JOIN public.radio_slots rs ON rs.id = rb.slot_id
WHERE bt.reference_type = 'radio_bid'
  AND bt.type = 'refund'
  AND bt.reference_id = rb.id
  AND bt.description ~ '^\?';

-- ============================================================
-- 5. Починка повреждённых записей в notifications
-- ============================================================

UPDATE public.notifications n
SET title = E'\u0421\u0442\u0430\u0432\u043a\u0430 \u043f\u0440\u0438\u043d\u044f\u0442\u0430',
    message = E'\u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || (n.data ->> 'amount') || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || rs.slot_number
FROM public.radio_slots rs
WHERE n.type = 'radio_bid_placed'
  AND (n.data ->> 'slot_id')::uuid = rs.id
  AND (n.title ~ '^\?' OR n.message ~ '^\?');

UPDATE public.notifications n
SET title = E'\u0412\u0430\u0448\u0443 \u0441\u0442\u0430\u0432\u043a\u0443 \u043f\u0435\u0440\u0435\u0431\u0438\u043b\u0438!',
    message = E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || (n.data ->> 'your_amount') || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || rs.slot_number
      || E' \u043f\u0435\u0440\u0435\u0431\u0438\u0442\u0430 (' || (n.data ->> 'new_highest') || E'\u20bd). \u041f\u043e\u0434\u043d\u0438\u043c\u0438\u0442\u0435 \u0441\u0442\u0430\u0432\u043a\u0443!'
FROM public.radio_slots rs
WHERE n.type = 'radio_bid_outbid'
  AND (n.data ->> 'slot_id')::uuid = rs.id
  AND (n.title ~ '^\?' OR n.message ~ '^\?');

UPDATE public.notifications n
SET title = E'\u0421\u0442\u0430\u0432\u043a\u0430 \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430',
    message = E'\u0421\u043b\u043e\u0442 #' || rs.slot_number || E' \u0437\u0430\u0432\u0435\u0440\u0448\u0451\u043d. \u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || (n.data ->> 'amount') || E'\u20bd \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430 \u043d\u0430 \u0431\u0430\u043b\u0430\u043d\u0441.'
FROM public.radio_slots rs
WHERE n.type = 'radio_bid_refunded'
  AND (n.data ->> 'slot_id')::uuid = rs.id
  AND (n.title ~ '^\?' OR n.message ~ '^\?');

UPDATE public.notifications n
SET title = E'\u0412\u044b \u0432\u044b\u0438\u0433\u0440\u0430\u043b\u0438 \u0430\u0443\u043a\u0446\u0438\u043e\u043d!',
    message = E'\u0412\u0430\u0448 \u0442\u0440\u0435\u043a \u043f\u043e\u043f\u0430\u0434\u0451\u0442 \u0432 \u044d\u0444\u0438\u0440 \u0440\u0430\u0434\u0438\u043e (\u0441\u043b\u043e\u0442 #' || rs.slot_number || E', \u0441\u0442\u0430\u0432\u043a\u0430 ' || (n.data ->> 'amount') || E'\u20bd)!'
FROM public.radio_slots rs
WHERE n.type = 'radio_bid_won'
  AND (n.data ->> 'slot_id')::uuid = rs.id
  AND (n.title ~ '^\?' OR n.message ~ '^\?');

-- ============================================================
-- 6. Auction config: убрать commission_percent, добавить enabled
-- ============================================================

UPDATE public.radio_config
SET value = value - 'commission_percent' || '{"enabled": true}'::jsonb,
    updated_at = NOW()
WHERE key = 'auction';
