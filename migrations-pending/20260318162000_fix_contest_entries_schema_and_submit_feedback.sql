-- Fix local drift in contest_entries schema and improve submit feedback.

ALTER TABLE public.contest_entries
  ADD COLUMN IF NOT EXISTS score NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS votes_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rank INTEGER,
  ADD COLUMN IF NOT EXISTS withdrawn_at TIMESTAMPTZ;

UPDATE public.contest_entries
SET status = 'active'
WHERE status IS NULL OR status = 'submitted';

UPDATE public.contest_entries ce
SET votes_count = v.votes_count
FROM (
  SELECT entry_id, COUNT(*)::INTEGER AS votes_count
  FROM public.contest_votes
  GROUP BY entry_id
) v
WHERE v.entry_id = ce.id
  AND COALESCE(ce.votes_count, -1) IS DISTINCT FROM v.votes_count;

DROP VIEW IF EXISTS public.active_contest_entries;

CREATE VIEW public.active_contest_entries
WITH (security_invoker = true)
AS
SELECT
  ce.id,
  ce.contest_id,
  ce.track_id,
  ce.user_id,
  COALESCE(ce.votes_count, 0) AS votes_count,
  ce.rank,
  COALESCE(ce.score, 0) AS score,
  ce.status,
  ce.withdrawn_at,
  ce.created_at,
  ce.entry_fee_charged,
  ce.entry_fee_charged_at,
  ce.entry_fee_refunded_at
FROM public.contest_entries ce
WHERE COALESCE(ce.status, 'active') = 'active';

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

  IF COALESCE(v_contest.entry_fee, 0) > 0 THEN
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
      CASE WHEN COALESCE(v_contest.entry_fee, 0) > 0 THEN now() ELSE NULL END,
      NULL
    );
  ELSE
    UPDATE public.contest_entries
    SET status = 'active',
        withdrawn_at = NULL,
        entry_fee_charged = COALESCE(v_contest.entry_fee, 0),
        entry_fee_charged_at = CASE WHEN COALESCE(v_contest.entry_fee, 0) > 0 THEN now() ELSE entry_fee_charged_at END,
        entry_fee_refunded_at = NULL
    WHERE id = v_entry_id;
  END IF;

  IF COALESCE(v_contest.entry_fee, 0) > 0 THEN
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
