-- Make voluntary contest withdrawals non-refundable and avoid double-charging restored entries.

CREATE OR REPLACE FUNCTION public.submit_contest_entry(
  p_contest_id UUID,
  p_track_id UUID,
  p_user_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := COALESCE(p_user_id, auth.uid());
  v_role TEXT := COALESCE(current_setting('request.jwt.claim.role', true), '');
  v_contest RECORD;
  v_track RECORD;
  v_existing RECORD;
  v_existing_found BOOLEAN := false;
  v_entries_count INTEGER := 0;
  v_entry_id UUID := gen_random_uuid();
  v_balance_before INTEGER;
  v_balance_after INTEGER;
  v_should_charge_fee BOOLEAN := false;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Необходима авторизация';
  END IF;

  SELECT *
  INTO v_contest
  FROM public.contests
  WHERE id = p_contest_id
  FOR UPDATE;

  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;

  IF v_contest.status <> 'active' THEN
    RAISE EXCEPTION 'Конкурс не принимает заявки';
  END IF;

  SELECT id, user_id, genre_id, created_at, audio_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Трек не найден';
  END IF;

  IF v_track.user_id <> v_actor_id AND NOT public.is_admin(v_actor_id) AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Можно подавать только собственный трек';
  END IF;

  IF v_track.audio_url IS NULL THEN
    RAISE EXCEPTION 'Трек ещё не готов для участия';
  END IF;

  IF v_contest.genre_id IS NOT NULL AND v_track.genre_id IS DISTINCT FROM v_contest.genre_id THEN
    RAISE EXCEPTION 'Жанр трека не соответствует требованиям конкурса';
  END IF;

  IF COALESCE(v_contest.require_new_track, false) AND EXISTS (
    SELECT 1
    FROM public.contest_entries ce
    WHERE ce.track_id = p_track_id
      AND ce.contest_id <> p_contest_id
  ) THEN
    RAISE EXCEPTION 'Трек уже использовался в другом конкурсе';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.contest_entries
  WHERE contest_id = p_contest_id
    AND track_id = p_track_id
  LIMIT 1
  FOR UPDATE;

  v_existing_found := FOUND;

  IF v_existing_found AND COALESCE(v_existing.status, 'active') = 'active' THEN
    RAISE EXCEPTION 'Этот трек уже участвует в конкурсе';
  END IF;

  SELECT COUNT(*) INTO v_entries_count
  FROM public.active_contest_entries
  WHERE contest_id = p_contest_id
    AND user_id = v_actor_id;

  IF v_entries_count >= COALESCE(v_contest.max_entries_per_user, 1) THEN
    RAISE EXCEPTION 'Достигнут лимит заявок';
  END IF;

  IF v_existing_found THEN
    v_entry_id := v_existing.id;
  END IF;

  v_should_charge_fee := COALESCE(v_contest.entry_fee, 0) > 0;

  IF v_existing_found
     AND COALESCE(v_existing.status, 'withdrawn') = 'withdrawn'
     AND COALESCE(v_existing.entry_fee_charged, 0) > 0
     AND v_existing.entry_fee_refunded_at IS NULL THEN
    v_should_charge_fee := false;
  END IF;

  IF v_should_charge_fee THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = v_actor_id
    FOR UPDATE;

    IF v_balance_before IS NULL OR v_balance_before < v_contest.entry_fee THEN
      RAISE EXCEPTION 'Недостаточно средств для участия';
    END IF;

    UPDATE public.profiles
    SET balance = balance - v_contest.entry_fee
    WHERE user_id = v_actor_id
    RETURNING balance INTO v_balance_after;
  END IF;

  IF NOT v_existing_found THEN
    INSERT INTO public.contest_entries (
      id,
      contest_id,
      track_id,
      user_id,
      status,
      entry_fee_charged,
      entry_fee_charged_at,
      entry_fee_refunded_at
    )
    VALUES (
      v_entry_id,
      p_contest_id,
      p_track_id,
      v_actor_id,
      'active',
      COALESCE(v_contest.entry_fee, 0),
      CASE WHEN v_should_charge_fee THEN now() ELSE NULL END,
      NULL
    );
  ELSE
    UPDATE public.contest_entries
    SET status = 'active',
        withdrawn_at = NULL,
        entry_fee_charged = CASE
          WHEN v_should_charge_fee THEN COALESCE(v_contest.entry_fee, 0)
          ELSE COALESCE(v_existing.entry_fee_charged, 0)
        END,
        entry_fee_charged_at = CASE
          WHEN v_should_charge_fee THEN now()
          ELSE v_existing.entry_fee_charged_at
        END,
        entry_fee_refunded_at = CASE
          WHEN v_should_charge_fee THEN NULL
          ELSE v_existing.entry_fee_refunded_at
        END
    WHERE id = v_entry_id;
  END IF;

  IF v_should_charge_fee THEN
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
    )
    VALUES (
      v_actor_id,
      -v_contest.entry_fee,
      'contest_entry_fee',
      'Вступительный взнос в конкурс "' || v_contest.title || '"',
      v_entry_id,
      'contest_entry',
      v_balance_before,
      v_balance_after,
      jsonb_build_object('contest_id', p_contest_id, 'track_id', p_track_id)
    );
  END IF;

  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.withdraw_contest_entry(_entry_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_contest RECORD;
BEGIN
  SELECT *
  INTO v_entry
  FROM public.contest_entries
  WHERE id = _entry_id
  FOR UPDATE;

  IF v_entry IS NULL THEN
    RAISE EXCEPTION 'Заявка не найдена';
  END IF;

  IF v_entry.user_id <> auth.uid() AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Нет прав на отзыв заявки';
  END IF;

  SELECT *
  INTO v_contest
  FROM public.contests
  WHERE id = v_entry.contest_id
  FOR UPDATE;

  IF v_contest.status IN ('voting', 'completed', 'cancelled') THEN
    RAISE EXCEPTION 'Нельзя отозвать заявку после начала голосования';
  END IF;

  IF COALESCE(v_entry.status, 'active') = 'withdrawn' THEN
    RETURN true;
  END IF;

  UPDATE public.contest_entries
  SET status = 'withdrawn',
      withdrawn_at = now()
  WHERE id = _entry_id;

  RETURN true;
END;
$$;
