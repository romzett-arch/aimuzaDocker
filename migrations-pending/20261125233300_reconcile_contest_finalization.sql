-- Restore dependencies expected by contest finalization and prize review.
ALTER TABLE public.contest_winners ADD COLUMN IF NOT EXISTS prize_awarded boolean;
UPDATE public.contest_winners
SET prize_awarded = (awarded_at IS NOT NULL)
WHERE prize_awarded IS NULL;
ALTER TABLE public.contest_winners ALTER COLUMN prize_awarded SET DEFAULT false;

CREATE OR REPLACE FUNCTION public.get_entry_jury_score(entry_uuid uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(AVG(score), 0)
  FROM public.contest_jury_scores
  WHERE entry_id = entry_uuid
$$;

REVOKE EXECUTE ON FUNCTION public.get_entry_jury_score(uuid)
FROM PUBLIC, anon, authenticated, service_role, aimuza_gateway;

-- Use a CTE so one lifecycle tick can finalize multiple contests in one transaction.
CREATE OR REPLACE FUNCTION public.finalize_contest(
  p_contest_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contest RECORD;
  v_entries_count INTEGER := 0;
  v_prize_pool INTEGER := 0;
  v_winners_count INTEGER := 0;
  v_existing_winners INTEGER := 0;
  v_entry RECORD;
  v_distribution RECORD;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT *
  INTO v_contest
  FROM public.contests
  WHERE id = p_contest_id
  FOR UPDATE;

  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;

  SELECT COUNT(*) INTO v_existing_winners
  FROM public.contest_winners
  WHERE contest_id = p_contest_id;

  IF v_existing_winners > 0 THEN
    UPDATE public.contests
    SET status = CASE WHEN status = 'cancelled' THEN status ELSE 'completed' END,
        final_prize_pool = COALESCE(final_prize_pool, public.calculate_contest_prize_pool(p_contest_id)),
        finalized_at = COALESCE(finalized_at, now())
    WHERE id = p_contest_id;

    RETURN v_existing_winners;
  END IF;

  SELECT COUNT(*) INTO v_entries_count
  FROM public.active_contest_entries
  WHERE contest_id = p_contest_id;

  IF v_entries_count < COALESCE(v_contest.min_participants, 1) THEN
    FOR v_entry IN
      SELECT *
      FROM public.contest_entries
      WHERE contest_id = p_contest_id
        AND COALESCE(status, 'active') = 'active'
        AND COALESCE(entry_fee_charged, 0) > 0
        AND entry_fee_refunded_at IS NULL
      FOR UPDATE
    LOOP
      SELECT balance INTO v_balance_before
      FROM public.profiles
      WHERE user_id = v_entry.user_id
      FOR UPDATE;

      UPDATE public.profiles
      SET balance = balance + v_entry.entry_fee_charged
      WHERE user_id = v_entry.user_id
      RETURNING balance INTO v_balance_after;

      UPDATE public.contest_entries
      SET entry_fee_refunded_at = now()
      WHERE id = v_entry.id;

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
        v_entry.user_id,
        v_entry.entry_fee_charged,
        'contest_entry_refund',
        'Возврат взноса: конкурс "' || v_contest.title || '" не состоялся',
        v_entry.id,
        'contest_entry',
        v_balance_before,
        v_balance_after,
        jsonb_build_object('contest_id', p_contest_id, 'reason', 'not_enough_participants')
      );
    END LOOP;

    UPDATE public.contests
    SET status = 'cancelled',
        final_prize_pool = 0,
        finalized_at = now()
    WHERE id = p_contest_id;

    RETURN 0;
  END IF;

  v_prize_pool := public.calculate_contest_prize_pool(p_contest_id, v_entries_count);

  UPDATE public.contest_entries
  SET rank = NULL
  WHERE contest_id = p_contest_id;

  WITH votes_stats AS (
    SELECT COALESCE(MAX(votes_count), 0) AS max_votes
    FROM public.active_contest_entries
    WHERE contest_id = p_contest_id
  ),
  scored AS (
    SELECT
      ce.id,
      ce.user_id,
      ce.votes_count,
      ce.created_at,
      public.get_entry_jury_score(ce.id) AS jury_score,
      CASE COALESCE(v_contest.scoring_mode, 'votes')
        WHEN 'jury' THEN public.get_entry_jury_score(ce.id)
        WHEN 'hybrid' THEN
          (
            CASE
              WHEN (SELECT max_votes FROM votes_stats) = 0 THEN 0
              ELSE (ce.votes_count::NUMERIC / (SELECT max_votes FROM votes_stats)) * 10
            END
          ) * (1 - COALESCE(v_contest.jury_weight, 0.5))
          + public.get_entry_jury_score(ce.id) * COALESCE(v_contest.jury_weight, 0.5)
        ELSE ce.votes_count::NUMERIC
      END AS final_score
    FROM public.active_contest_entries ce
    WHERE ce.contest_id = p_contest_id
  ),
  ranked AS (
    SELECT
      *,
      ROW_NUMBER() OVER (
        ORDER BY final_score DESC, votes_count DESC, created_at ASC, id ASC
      ) AS place
    FROM scored
    WHERE final_score > 0
      AND (
        COALESCE(v_contest.scoring_mode, 'votes') = 'jury'
        OR votes_count >= COALESCE(v_contest.min_votes_to_win, 0)
      )
  ),
  winners AS (
    INSERT INTO public.contest_winners (contest_id, entry_id, user_id, place, prize_amount, prize_awarded)
    SELECT p_contest_id, ranked.id, ranked.user_id, ranked.place, COALESCE(prizes.prize_amount, 0), false
    FROM ranked
    LEFT JOIN public.get_contest_prize_distribution(p_contest_id, v_prize_pool) prizes
      ON prizes.place = ranked.place
    WHERE ranked.place <= 3
    RETURNING entry_id, place
  )
  UPDATE public.contest_entries AS entry
  SET rank = winners.place
  FROM winners
  WHERE entry.id = winners.entry_id;
  GET DIAGNOSTICS v_winners_count = ROW_COUNT;

  UPDATE public.contests
  SET status = 'completed',
      final_prize_pool = v_prize_pool,
      finalized_at = now()
  WHERE id = p_contest_id;

  RETURN v_winners_count;
END;
$$;
