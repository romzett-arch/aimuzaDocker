-- =====================================================
-- Balance Transactions Logging (CFO Financial Model v2)
-- Add INSERT into balance_transactions for all operations
-- that modify profiles.balance but currently don't log
-- =====================================================

-- 1. admin_adjust_balance RPC (replaces direct PATCH profiles.balance)
CREATE OR REPLACE FUNCTION public.admin_adjust_balance(
  p_user_id UUID,
  p_amount INTEGER,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF NOT (public.is_admin(v_caller) OR public.is_super_admin(v_caller)) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT balance INTO v_balance_before FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance_before IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Профиль не найден');
  END IF;

  v_balance_after := v_balance_before + p_amount;
  IF v_balance_after < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Баланс не может быть отрицательным');
  END IF;

  UPDATE public.profiles SET balance = v_balance_after WHERE user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, balance_before, balance_after, metadata)
  VALUES (
    p_user_id,
    p_amount,
    'admin_adjust',
    COALESCE(p_reason, 'Корректировка баланса администратором: ' || p_amount || ' ₽'),
    v_balance_before,
    v_balance_after,
    jsonb_build_object('admin_id', v_caller)
  );

  RETURN jsonb_build_object('success', true, 'new_balance', v_balance_after);
END;
$$;

-- 2. register_referral — add INSERT into balance_transactions for referee bonus
CREATE OR REPLACE FUNCTION public.register_referral(
  p_referee_id uuid,
  p_referral_code text,
  p_ip_address text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_source text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer_id uuid;
  v_code_id uuid;
  v_referee_bonus numeric;
  v_referrer_bonus numeric;
  v_settings jsonb;
  v_balance_before integer;
  v_balance_after integer;
BEGIN
  SELECT value::text::boolean INTO v_settings
  FROM referral_settings WHERE key = 'program_enabled';

  IF NOT COALESCE(v_settings, true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Реферальная программа отключена');
  END IF;

  SELECT rc.user_id, rc.id INTO v_referrer_id, v_code_id
  FROM referral_codes rc
  WHERE rc.code = upper(p_referral_code) OR rc.custom_code = p_referral_code;

  IF v_referrer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Код не найден');
  END IF;

  IF v_referrer_id = p_referee_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Нельзя использовать собственный код');
  END IF;

  IF EXISTS(SELECT 1 FROM referrals WHERE referee_id = p_referee_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Пользователь уже зарегистрирован по реферальной ссылке');
  END IF;

  SELECT (value)::numeric INTO v_referee_bonus FROM referral_settings WHERE key = 'referee_bonus';
  SELECT (value)::numeric INTO v_referrer_bonus FROM referral_settings WHERE key = 'referrer_bonus';

  INSERT INTO referrals (referrer_id, referee_id, referral_code_id, ip_address, user_agent, source)
  VALUES (v_referrer_id, p_referee_id, v_code_id, p_ip_address, p_user_agent, p_source);

  IF COALESCE(v_referee_bonus, 0) > 0 THEN
    SELECT balance INTO v_balance_before FROM profiles WHERE user_id = p_referee_id;
    v_balance_after := COALESCE(v_balance_before, 0) + (v_referee_bonus)::integer;

    UPDATE profiles SET balance = COALESCE(balance, 0) + (v_referee_bonus)::integer WHERE user_id = p_referee_id;

    INSERT INTO balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    VALUES (p_referee_id, (v_referee_bonus)::integer, 'referral_bonus',
      'Бонус за регистрацию по реферальной ссылке',
      'referral', v_code_id, COALESCE(v_balance_before, 0), v_balance_after);

    INSERT INTO referral_rewards (user_id, amount, type, description, source_event)
    VALUES (p_referee_id, v_referee_bonus, 'welcome_bonus', 'Бонус за регистрацию по реферальной ссылке', 'registration');
  END IF;

  INSERT INTO referral_stats (user_id, date, registrations)
  VALUES (v_referrer_id, CURRENT_DATE, 1)
  ON CONFLICT (user_id, date) DO UPDATE SET registrations = referral_stats.registrations + 1;

  RETURN jsonb_build_object(
    'success', true,
    'referrer_id', v_referrer_id,
    'bonus_received', v_referee_bonus
  );
END;
$$;

-- 3. activate_referral — add INSERT into balance_transactions
CREATE OR REPLACE FUNCTION public.activate_referral(p_referee_id uuid, p_deposit_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral record;
  v_min_deposit numeric;
  v_referrer_bonus numeric;
  v_balance_before integer;
  v_balance_after integer;
BEGIN
  SELECT * INTO v_referral FROM referrals WHERE referee_id = p_referee_id AND status = 'pending';

  IF v_referral IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Реферал не найден или уже активирован');
  END IF;

  SELECT (value)::numeric INTO v_min_deposit FROM referral_settings WHERE key = 'min_deposit_to_activate';

  IF p_deposit_amount < COALESCE(v_min_deposit, 0) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Сумма депозита меньше минимальной');
  END IF;

  SELECT (value)::numeric INTO v_referrer_bonus FROM referral_settings WHERE key = 'referrer_bonus';

  UPDATE referrals SET status = 'active', activated_at = now() WHERE id = v_referral.id;

  IF COALESCE(v_referrer_bonus, 0) > 0 THEN
    SELECT balance INTO v_balance_before FROM profiles WHERE user_id = v_referral.referrer_id;
    v_balance_after := COALESCE(v_balance_before, 0) + (v_referrer_bonus)::integer;

    UPDATE profiles SET balance = COALESCE(balance, 0) + (v_referrer_bonus)::integer WHERE user_id = v_referral.referrer_id;

    INSERT INTO balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    VALUES (v_referral.referrer_id, (v_referrer_bonus)::integer, 'referral_bonus',
      'Бонус за активацию реферала', 'referral', v_referral.id, COALESCE(v_balance_before, 0), v_balance_after);

    INSERT INTO referral_rewards (user_id, referral_id, amount, type, description, source_event)
    VALUES (v_referral.referrer_id, v_referral.id, v_referrer_bonus, 'activation_bonus', 'Бонус за активацию реферала', 'activation');
  END IF;

  INSERT INTO referral_stats (user_id, date, activations, earnings)
  VALUES (v_referral.referrer_id, CURRENT_DATE, 1, v_referrer_bonus)
  ON CONFLICT (user_id, date) DO UPDATE SET
    activations = referral_stats.activations + 1,
    earnings = referral_stats.earnings + v_referrer_bonus;

  RETURN jsonb_build_object('success', true, 'bonus_paid', v_referrer_bonus);
END;
$$;

-- 4. process_referral_deposit_bonus — add INSERT into balance_transactions
CREATE OR REPLACE FUNCTION public.process_referral_deposit_bonus(p_referee_id uuid, p_deposit_amount numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral record;
  v_percent numeric;
  v_bonus numeric;
  v_balance_before integer;
  v_balance_after integer;
BEGIN
  SELECT * INTO v_referral FROM referrals WHERE referee_id = p_referee_id AND status = 'active';

  IF v_referral IS NULL THEN
    RETURN;
  END IF;

  SELECT (value)::numeric INTO v_percent FROM referral_settings WHERE key = 'bonus_per_deposit_percent';

  IF COALESCE(v_percent, 0) <= 0 THEN
    RETURN;
  END IF;

  v_bonus := ROUND(p_deposit_amount * v_percent / 100, 2);

  IF v_bonus > 0 THEN
    SELECT balance INTO v_balance_before FROM profiles WHERE user_id = v_referral.referrer_id;
    v_balance_after := COALESCE(v_balance_before, 0) + (v_bonus)::integer;

    UPDATE profiles SET balance = COALESCE(balance, 0) + (v_bonus)::integer WHERE user_id = v_referral.referrer_id;

    INSERT INTO balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    VALUES (v_referral.referrer_id, (v_bonus)::integer, 'referral_bonus',
      'Процент от депозита реферала (' || v_percent || '%)', 'referral', v_referral.id, COALESCE(v_balance_before, 0), v_balance_after);

    INSERT INTO referral_rewards (user_id, referral_id, amount, type, description, source_event)
    VALUES (v_referral.referrer_id, v_referral.id, v_bonus, 'deposit_percent',
      'Процент от депозита реферала (' || v_percent || '%)', 'deposit');

    INSERT INTO referral_stats (user_id, date, earnings)
    VALUES (v_referral.referrer_id, CURRENT_DATE, v_bonus)
    ON CONFLICT (user_id, date) DO UPDATE SET earnings = referral_stats.earnings + v_bonus;
  END IF;
END;
$$;

-- 5. award_contest_prize — add INSERT into balance_transactions
CREATE OR REPLACE FUNCTION public.award_contest_prize(_contest_id uuid, _winner_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_contest RECORD;
  v_winner RECORD;
  v_balance_before integer;
  v_balance_after integer;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT id, title, prize_amount INTO v_contest
  FROM public.contests WHERE id = _contest_id;

  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;

  SELECT * INTO v_winner
  FROM public.contest_winners
  WHERE id = _winner_id AND contest_id = _contest_id;

  IF v_winner IS NULL THEN
    RAISE EXCEPTION 'Победитель не найден';
  END IF;

  IF v_winner.prize_awarded THEN
    RAISE EXCEPTION 'Приз уже выплачен';
  END IF;

  IF v_winner.place = 1 AND v_contest.prize_amount > 0 THEN
    SELECT balance INTO v_balance_before FROM public.profiles WHERE user_id = v_winner.user_id;
    v_balance_after := COALESCE(v_balance_before, 0) + (v_contest.prize_amount)::integer;

    UPDATE public.profiles
    SET balance = balance + (v_contest.prize_amount)::integer
    WHERE user_id = v_winner.user_id;

    INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    VALUES (v_winner.user_id, (v_contest.prize_amount)::integer, 'contest_prize',
      'Приз за победу в конкурсе "' || v_contest.title || '"', 'contest', _contest_id,
      COALESCE(v_balance_before, 0), v_balance_after);

    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_winner.user_id,
      'prize_awarded',
      '💰 Приз начислен!',
      'На ваш баланс зачислено ' || v_contest.prize_amount || ' ₽ за победу в конкурсе "' || v_contest.title || '"',
      'contest',
      _contest_id
    );
  END IF;

  UPDATE public.contest_winners
  SET prize_awarded = true
  WHERE id = _winner_id;

  RETURN true;
END;
$$;

-- 6. radio_resolve_predictions — add INSERT into balance_transactions for wins
CREATE OR REPLACE FUNCTION public.radio_resolve_predictions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_rec RECORD;
  v_actual_hit BOOLEAN;
  v_payout INTEGER;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  FOR v_rec IN
    SELECT rp.id, rp.track_id, rp.predicted_hit, rp.bet_amount, rp.user_id
    FROM public.radio_predictions rp
    WHERE rp.status = 'pending' AND rp.expires_at < now()
  LOOP
    SELECT (COALESCE(t.likes_count, 0) >= 5) INTO v_actual_hit
    FROM public.tracks t WHERE t.id = v_rec.track_id;

    v_payout := CASE WHEN v_actual_hit = v_rec.predicted_hit THEN (v_rec.bet_amount * 1.8)::INTEGER ELSE 0 END;

    UPDATE public.radio_predictions SET
      actual_result = v_actual_hit,
      status = CASE WHEN v_actual_hit = v_rec.predicted_hit THEN 'won' ELSE 'lost' END,
      payout = v_payout
    WHERE id = v_rec.id;

    IF v_actual_hit = v_rec.predicted_hit AND v_payout > 0 THEN
      SELECT balance INTO v_balance_before FROM public.profiles WHERE user_id = v_rec.user_id;
      v_balance_after := COALESCE(v_balance_before, 0) + v_payout;

      UPDATE public.profiles SET balance = balance + v_payout WHERE user_id = v_rec.user_id;

      INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
      VALUES (v_rec.user_id, v_payout, 'radio_win',
        'Выигрыш прогноза: ' || v_payout || ' ₽',
        'radio_prediction', v_rec.id, COALESCE(v_balance_before, 0), v_balance_after);
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- 7. radio_place_prediction — add INSERT into balance_transactions
CREATE OR REPLACE FUNCTION public.radio_place_prediction(
  p_user_id UUID,
  p_track_id UUID,
  p_bet_amount INTEGER,
  p_predicted_hit BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_min INTEGER := 5;
  v_max INTEGER := 100;
  v_balance INTEGER;
  v_expires_hours INTEGER := 24;
  v_caller UUID;
  v_prediction_id UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_bet_amount < v_min OR p_bet_amount > v_max THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bet_amount', 'min', v_min, 'max', v_max);
  END IF;

  IF EXISTS (SELECT 1 FROM public.radio_predictions WHERE user_id = p_user_id AND track_id = p_track_id AND status = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_predicted');
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_bet_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  INSERT INTO public.radio_predictions (user_id, track_id, bet_amount, predicted_hit, expires_at)
  VALUES (p_user_id, p_track_id, p_bet_amount, p_predicted_hit, now() + (v_expires_hours || ' hours')::interval)
  RETURNING id INTO v_prediction_id;

  UPDATE public.profiles SET balance = balance - p_bet_amount WHERE user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  SELECT p_user_id, -p_bet_amount, 'radio_prediction',
    'Ставка на прогноз: ' || p_bet_amount || ' ₽',
    'radio_prediction', v_prediction_id,
    balance + p_bet_amount, balance
  FROM public.profiles WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'bet_amount', p_bet_amount, 'predicted_hit', p_predicted_hit, 'expires_in_hours', v_expires_hours);
END;
$$;

-- 8. radio_skip_ad — add INSERT into balance_transactions
CREATE OR REPLACE FUNCTION public.radio_skip_ad(
  p_user_id UUID,
  p_ad_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_skip_price INTEGER := 5;
  v_balance INTEGER;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_skip_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - v_skip_price WHERE user_id = p_user_id;
  UPDATE public.radio_ad_placements SET clicks = clicks + 1 WHERE id = p_ad_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  SELECT p_user_id, -v_skip_price, 'radio_skip',
    'Пропуск рекламы: ' || v_skip_price || ' ₽',
    'radio_ad', p_ad_id,
    balance + v_skip_price, balance
  FROM public.profiles WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'charged', v_skip_price);
END;
$$;

-- 9. forum_purchase_promo — add INSERT into balance_transactions (uses user_id for BT; profiles may use id in UPDATE)
CREATE OR REPLACE FUNCTION public.forum_purchase_promo(
  p_user_id UUID,
  p_promo_type TEXT,
  p_category_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
  v_price NUMERIC;
  v_duration INT;
  v_settings JSONB;
  v_max_active INT;
  v_active_count INT;
  v_slot_id UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';
  IF v_settings IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Настройки промо не найдены');
  END IF;

  v_price := (v_settings->'prices'->>p_promo_type)::numeric;
  v_duration := (v_settings->'durations'->>p_promo_type)::int;
  IF v_price IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Неверный тип промо');
  END IF;

  SELECT balance INTO v_balance FROM profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств. Необходимо: ' || v_price || ' ₽');
  END IF;

  v_max_active := COALESCE((v_settings->>'max_active_per_user')::int, 3);
  SELECT COUNT(*) INTO v_active_count
  FROM forum_promo_slots
  WHERE user_id = p_user_id AND status IN ('pending_content', 'pending_moderation', 'approved');

  IF v_active_count >= v_max_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'Максимум активных промо: ' || v_max_active);
  END IF;

  v_balance_before := (v_balance)::integer;
  v_balance_after := v_balance_before - (v_price)::integer;

  UPDATE profiles SET balance = balance - v_price WHERE user_id = p_user_id;

  INSERT INTO forum_promo_slots (user_id, promo_type, status, price_rub, duration_days, category_id)
  VALUES (p_user_id, p_promo_type::forum_promo_type, 'pending_content', v_price, v_duration, p_category_id)
  RETURNING id INTO v_slot_id;

  INSERT INTO balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  VALUES (p_user_id, -(v_price)::integer, 'forum_promo',
    'Покупка промо-слота: ' || v_price || ' ₽',
    'forum_promo_slot', v_slot_id, v_balance_before, v_balance_after);

  RETURN jsonb_build_object(
    'success', true,
    'slot_id', v_slot_id,
    'price', v_price,
    'duration_days', v_duration,
    'message', 'Промо-слот куплен! Заполните контент и отправьте на модерацию.'
  );
END;
$$;

-- 10. forum_moderate_promo — add INSERT into balance_transactions for refund
CREATE OR REPLACE FUNCTION public.forum_moderate_promo(
  p_slot_id UUID,
  p_moderator_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot RECORD;
  v_settings JSONB;
  v_refund_percent INT;
  v_refund_amount NUMERIC;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  SELECT * INTO v_slot FROM forum_promo_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо не найдено');
  END IF;

  IF v_slot.status != 'pending_moderation' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо не на модерации');
  END IF;

  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';

  IF p_action = 'approve' THEN
    UPDATE forum_promo_slots SET
      status = 'approved',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      starts_at = now(),
      expires_at = now() + (v_slot.duration_days || ' days')::interval,
      updated_at = now()
    WHERE id = p_slot_id;

    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_approved', 'promo', p_slot_id::text, jsonb_build_object('promo_type', v_slot.promo_type));

    RETURN jsonb_build_object('success', true, 'message', 'Промо одобрено и опубликовано');

  ELSIF p_action = 'reject' THEN
    v_refund_percent := COALESCE((v_settings->>'refund_percent')::int, 100);
    v_refund_amount := v_slot.price_rub * v_refund_percent / 100;

    IF v_refund_amount > 0 AND COALESCE((v_settings->>'refund_on_rejection')::boolean, true) THEN
      SELECT balance INTO v_balance_before FROM profiles WHERE user_id = v_slot.user_id;
      v_balance_after := COALESCE(v_balance_before, 0) + (v_refund_amount)::integer;

      UPDATE profiles SET balance = balance + v_refund_amount WHERE user_id = v_slot.user_id;

      INSERT INTO balance_transactions (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
      VALUES (v_slot.user_id, (v_refund_amount)::integer, 'forum_promo_refund',
        'Возврат за отклонённый промо-слот: ' || v_refund_amount || ' ₽',
        'forum_promo_slot', p_slot_id, COALESCE(v_balance_before, 0), v_balance_after);
    END IF;

    UPDATE forum_promo_slots SET
      status = 'rejected',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      rejection_reason = p_reason,
      refunded = (v_refund_amount > 0),
      refund_amount = v_refund_amount,
      updated_at = now()
    WHERE id = p_slot_id;

    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_rejected', 'promo', p_slot_id::text,
      jsonb_build_object('reason', p_reason, 'refund', v_refund_amount));

    RETURN jsonb_build_object('success', true, 'message', 'Промо отклонено. Возврат: ' || v_refund_amount || ' ₽');
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Неверное действие');
  END IF;
END;
$$;

-- Grant execute for admin_adjust_balance
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.admin_adjust_balance(UUID, INTEGER, TEXT) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.admin_adjust_balance(UUID, INTEGER, TEXT) TO service_role;
  END IF;
END $$;
