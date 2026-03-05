-- Fix radio_place_bid: добавить аудит balance_transactions, рефанд старой ставки, уведомления
-- Fix radio_refund_losers: новая функция для возврата средств проигравшим

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
AS $$
DECLARE
  v_slot RECORD;
  v_min_bid INTEGER := 10;
  v_bid_step INTEGER := 5;
  v_highest INTEGER;
  v_balance INTEGER;
  v_old_bid RECORD;
  v_new_bid_id UUID;
  v_track_title TEXT;
BEGIN
  -- Валидация слота
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_found');
  END IF;
  IF v_slot.status NOT IN ('open', 'bidding') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  -- Проверка минимальной ставки
  SELECT COALESCE(MAX(amount), 0) INTO v_highest
    FROM public.radio_bids WHERE slot_id = p_slot_id AND status = 'active';
  IF p_amount < v_min_bid OR (v_highest > 0 AND p_amount < v_highest + v_bid_step) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_required', GREATEST(v_min_bid, v_highest + v_bid_step));
  END IF;

  -- Найти старую активную ставку этого пользователя на этот слот
  SELECT id, amount INTO v_old_bid
    FROM public.radio_bids
    WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active'
    ORDER BY amount DESC LIMIT 1;

  -- Рефанд старой ставки, если есть
  IF v_old_bid.id IS NOT NULL THEN
    UPDATE public.profiles SET balance = balance + v_old_bid.amount WHERE user_id = p_user_id;

    INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT p_user_id, v_old_bid.amount, 'refund',
           'Возврат предыдущей ставки на слот #' || v_slot.slot_number,
           'radio_bid', v_old_bid.id,
           balance - v_old_bid.amount, balance
    FROM public.profiles WHERE user_id = p_user_id;

    UPDATE public.radio_bids SET status = 'outbid' WHERE id = v_old_bid.id;
  END IF;

  -- Проверка баланса (после возможного рефанда)
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Списание
  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;

  -- Запись аудита списания
  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  SELECT p_user_id, -p_amount, 'debit',
         'Ставка ' || p_amount || '₽ на слот #' || v_slot.slot_number,
         'radio_slot', p_slot_id,
         balance + p_amount, balance
  FROM public.profiles WHERE user_id = p_user_id;

  -- Создание ставки
  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount)
  VALUES (p_slot_id, p_user_id, p_track_id, p_amount)
  RETURNING id INTO v_new_bid_id;

  -- Обновление слота
  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1 WHERE id = p_slot_id;

  -- Название трека для уведомлений
  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id;

  -- Уведомление: ставка принята
  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  VALUES (
    p_user_id,
    'radio_bid_placed',
    'Ставка принята',
    'Ваша ставка ' || p_amount || '₽ на слот #' || v_slot.slot_number || ' (трек: ' || COALESCE(v_track_title, '—') || ')',
    jsonb_build_object('slot_id', p_slot_id, 'bid_id', v_new_bid_id, 'amount', p_amount, 'track_id', p_track_id),
    '/radio'
  );

  -- Уведомить перебитых пользователей (чужие ставки, которые теперь проигрывают)
  -- Не меняем их статус — они ещё 'active', просто предупреждаем, что их перебили
  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  SELECT
    rb.user_id,
    'radio_bid_outbid',
    'Вашу ставку перебили!',
    'Ставка ' || rb.amount || '₽ на слот #' || v_slot.slot_number || ' перебита (' || p_amount || '₽). Поднимите ставку!',
    jsonb_build_object('slot_id', p_slot_id, 'your_amount', rb.amount, 'new_highest', p_amount),
    '/radio'
  FROM public.radio_bids rb
  WHERE rb.slot_id = p_slot_id
    AND rb.status = 'active'
    AND rb.user_id != p_user_id
    AND rb.amount < p_amount;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$$;

-- Функция рефанда проигравших (вызывается сервером при завершении аукциона)
CREATE OR REPLACE FUNCTION public.radio_refund_losers(p_slot_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
    -- Возврат на баланс
    UPDATE public.profiles SET balance = balance + v_bid.amount WHERE user_id = v_bid.user_id;

    -- Аудит
    INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT v_bid.user_id, v_bid.amount, 'refund',
           'Возврат ставки: слот #' || v_slot.slot_number || ' завершён',
           'radio_bid', v_bid.id,
           balance - v_bid.amount, balance
    FROM public.profiles WHERE user_id = v_bid.user_id;

    -- Пометка
    UPDATE public.radio_bids SET status = 'refunded' WHERE id = v_bid.id;

    -- Уведомление
    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_bid.user_id,
      'radio_bid_refunded',
      'Ставка возвращена',
      'Слот #' || v_slot.slot_number || ' завершён. Ваша ставка ' || v_bid.amount || '₽ возвращена на баланс.',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_bid.amount, 'refund', true),
      '/radio'
    );

    v_refund_count := v_refund_count + 1;
  END LOOP;

  -- Уведомление победителю
  IF v_slot.winner_user_id IS NOT NULL THEN
    -- Пометить выигравшую ставку
    UPDATE public.radio_bids SET status = 'won'
    WHERE slot_id = p_slot_id AND user_id = v_slot.winner_user_id AND status = 'active';

    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_slot.winner_user_id,
      'radio_bid_won',
      'Вы выиграли аукцион!',
      'Ваш трек попадёт в эфир радио (слот #' || v_slot.slot_number || ', ставка ' || v_slot.winning_bid || '₽)!',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_slot.winning_bid, 'track_id', v_slot.winner_track_id),
      '/radio'
    );
  END IF;

  RETURN v_refund_count;
END;
$$;

-- Функция автосоздания нового слота
CREATE OR REPLACE FUNCTION public.radio_create_next_slot()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.radio_place_bid(uuid, uuid, uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.radio_refund_losers(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.radio_create_next_slot() TO service_role;
