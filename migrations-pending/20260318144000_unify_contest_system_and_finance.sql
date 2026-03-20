-- ============================================================
-- Contest system: unify arena flow, finance and lifecycle
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Align schema with current frontend model
-- ─────────────────────────────────────────────────────────────

ALTER TABLE public.contests
  ADD COLUMN IF NOT EXISTS contest_type TEXT DEFAULT 'classic' CHECK (contest_type IN ('daily', 'weekly', 'seasonal', 'classic')),
  ADD COLUMN IF NOT EXISTS entry_fee INTEGER DEFAULT 0 CHECK (entry_fee >= 0),
  ADD COLUMN IF NOT EXISTS min_participants INTEGER DEFAULT 1 CHECK (min_participants >= 1),
  ADD COLUMN IF NOT EXISTS min_votes_to_win INTEGER DEFAULT 0 CHECK (min_votes_to_win >= 0),
  ADD COLUMN IF NOT EXISTS auto_finalize BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS season_id UUID,
  ADD COLUMN IF NOT EXISTS theme TEXT,
  ADD COLUMN IF NOT EXISTS prize_pool_formula TEXT DEFAULT 'fixed' CHECK (prize_pool_formula IN ('fixed', 'pool', 'dynamic')),
  ADD COLUMN IF NOT EXISTS prize_distribution JSONB DEFAULT '[0.6, 0.3, 0.1]'::jsonb,
  ADD COLUMN IF NOT EXISTS require_new_track BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS scoring_mode TEXT DEFAULT 'votes' CHECK (scoring_mode IN ('votes', 'jury', 'hybrid')),
  ADD COLUMN IF NOT EXISTS final_prize_pool INTEGER,
  ADD COLUMN IF NOT EXISTS finalized_at TIMESTAMPTZ;

ALTER TABLE public.contest_entries
  ADD COLUMN IF NOT EXISTS entry_fee_charged INTEGER DEFAULT 0 CHECK (entry_fee_charged >= 0),
  ADD COLUMN IF NOT EXISTS entry_fee_charged_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS entry_fee_refunded_at TIMESTAMPTZ;

ALTER TABLE public.contest_winners
  ADD COLUMN IF NOT EXISTS prize_amount INTEGER DEFAULT 0 CHECK (prize_amount >= 0),
  ADD COLUMN IF NOT EXISTS awarded_at TIMESTAMPTZ;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'contest_winners'
      AND column_name = 'prize_awarded'
  ) THEN
    ALTER TABLE public.contest_winners
      ALTER COLUMN prize_awarded SET DEFAULT false;
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────
-- 2. Arena справочники
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.contest_seasons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  start_date TIMESTAMPTZ NOT NULL,
  end_date TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'upcoming' CHECK (status IN ('upcoming', 'active', 'completed')),
  theme TEXT,
  grand_prize_amount INTEGER NOT NULL DEFAULT 0 CHECK (grand_prize_amount >= 0),
  grand_prize_description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_leagues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  tier INTEGER NOT NULL,
  min_rating INTEGER NOT NULL,
  max_rating INTEGER,
  icon_url TEXT,
  color TEXT NOT NULL DEFAULT '#64748b',
  multiplier NUMERIC(6,2) NOT NULL DEFAULT 1.0
);

CREATE TABLE IF NOT EXISTS public.contest_achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  icon TEXT NOT NULL DEFAULT 'trophy',
  xp_reward INTEGER NOT NULL DEFAULT 0,
  credit_reward INTEGER NOT NULL DEFAULT 0,
  rarity TEXT NOT NULL DEFAULT 'common' CHECK (rarity IN ('common', 'rare', 'epic', 'legendary')),
  condition_type TEXT NOT NULL,
  condition_value INTEGER NOT NULL DEFAULT 1 CHECK (condition_value >= 0)
);

CREATE TABLE IF NOT EXISTS public.contest_user_achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  achievement_id UUID NOT NULL REFERENCES public.contest_achievements(id) ON DELETE CASCADE,
  earned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, achievement_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_contest_leagues_tier_unique
  ON public.contest_leagues(tier);

CREATE UNIQUE INDEX IF NOT EXISTS idx_contest_achievements_key_unique
  ON public.contest_achievements(key);

ALTER TABLE public.contest_seasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_leagues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_user_achievements ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_seasons' AND policyname = 'Anyone can view contest seasons'
  ) THEN
    CREATE POLICY "Anyone can view contest seasons"
      ON public.contest_seasons FOR SELECT
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_seasons' AND policyname = 'Admins can manage contest seasons'
  ) THEN
    CREATE POLICY "Admins can manage contest seasons"
      ON public.contest_seasons FOR ALL
      USING (public.is_admin(auth.uid()));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_leagues' AND policyname = 'Anyone can view contest leagues'
  ) THEN
    CREATE POLICY "Anyone can view contest leagues"
      ON public.contest_leagues FOR SELECT
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_leagues' AND policyname = 'Admins can manage contest leagues'
  ) THEN
    CREATE POLICY "Admins can manage contest leagues"
      ON public.contest_leagues FOR ALL
      USING (public.is_admin(auth.uid()));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_achievements' AND policyname = 'Anyone can view contest achievements'
  ) THEN
    CREATE POLICY "Anyone can view contest achievements"
      ON public.contest_achievements FOR SELECT
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_achievements' AND policyname = 'Admins can manage contest achievements'
  ) THEN
    CREATE POLICY "Admins can manage contest achievements"
      ON public.contest_achievements FOR ALL
      USING (public.is_admin(auth.uid()));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_user_achievements' AND policyname = 'Users can view own contest achievements'
  ) THEN
    CREATE POLICY "Users can view own contest achievements"
      ON public.contest_user_achievements FOR SELECT
      USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'contest_user_achievements' AND policyname = 'Service and admins can manage contest achievements'
  ) THEN
    CREATE POLICY "Service and admins can manage contest achievements"
      ON public.contest_user_achievements FOR ALL
      USING (
        public.is_admin(auth.uid())
        OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
      );
  END IF;
END $$;

INSERT INTO public.contest_leagues (name, tier, min_rating, max_rating, color, multiplier)
VALUES
  ('Бронза', 1, 0, 999, '#cd7f32', 1.00),
  ('Серебро', 2, 1000, 1499, '#94a3b8', 1.10),
  ('Золото', 3, 1500, 1999, '#eab308', 1.25),
  ('Платина', 4, 2000, NULL, '#a855f7', 1.50)
ON CONFLICT (tier) DO UPDATE SET
  name = EXCLUDED.name,
  min_rating = EXCLUDED.min_rating,
  max_rating = EXCLUDED.max_rating,
  color = EXCLUDED.color,
  multiplier = EXCLUDED.multiplier;

INSERT INTO public.contest_achievements (key, name, description, icon, rarity, condition_type, condition_value)
VALUES
  ('first_step', 'Первый шаг', 'Первое участие в конкурсе', 'sparkles', 'common', 'participations', 1),
  ('regular', 'Постоянный участник', 'Пять участий в конкурсах', 'music', 'rare', 'participations', 5),
  ('first_win', 'Первая победа', 'Первая победа в конкурсе', 'trophy', 'rare', 'wins', 1),
  ('podium', 'Подиум', 'Три попадания в топ-3', 'medal', 'epic', 'top3', 3)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  rarity = EXCLUDED.rarity,
  condition_type = EXCLUDED.condition_type,
  condition_value = EXCLUDED.condition_value;

-- ─────────────────────────────────────────────────────────────
-- 3. Helper functions
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.calculate_contest_prize_pool(
  p_contest_id UUID,
  p_entries_count INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contest RECORD;
  v_entries_count INTEGER := COALESCE(p_entries_count, 0);
BEGIN
  SELECT prize_amount, entry_fee, prize_pool_formula
  INTO v_contest
  FROM public.contests
  WHERE id = p_contest_id;

  IF v_contest IS NULL THEN
    RETURN 0;
  END IF;

  IF p_entries_count IS NULL THEN
    SELECT COUNT(*) INTO v_entries_count
    FROM public.active_contest_entries
    WHERE contest_id = p_contest_id;
  END IF;

  CASE COALESCE(v_contest.prize_pool_formula, 'fixed')
    WHEN 'pool' THEN
      RETURN GREATEST(ROUND(COALESCE(v_contest.entry_fee, 0) * v_entries_count * 0.8), 0);
    WHEN 'dynamic' THEN
      RETURN GREATEST(COALESCE(v_contest.prize_amount, 0) + ROUND(LN(GREATEST(v_entries_count, 1)) * 100), 0);
    ELSE
      RETURN GREATEST(COALESCE(v_contest.prize_amount, 0), 0);
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_contest_prize_distribution(
  p_contest_id UUID,
  p_prize_pool INTEGER DEFAULT NULL
)
RETURNS TABLE(place INTEGER, prize_amount INTEGER)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contest RECORD;
  v_pool INTEGER := COALESCE(p_prize_pool, 0);
  v_share_1 NUMERIC := 0.6;
  v_share_2 NUMERIC := 0.3;
  v_share_3 NUMERIC := 0.1;
  v_prize_1 INTEGER := 0;
  v_prize_2 INTEGER := 0;
  v_prize_3 INTEGER := 0;
BEGIN
  SELECT prize_distribution
  INTO v_contest
  FROM public.contests
  WHERE id = p_contest_id;

  IF p_prize_pool IS NULL THEN
    v_pool := public.calculate_contest_prize_pool(p_contest_id);
  END IF;

  IF v_contest IS NOT NULL
     AND jsonb_typeof(v_contest.prize_distribution) = 'array'
     AND jsonb_array_length(v_contest.prize_distribution) >= 3 THEN
    v_share_1 := COALESCE((v_contest.prize_distribution->>0)::NUMERIC, 0.6);
    v_share_2 := COALESCE((v_contest.prize_distribution->>1)::NUMERIC, 0.3);
    v_share_3 := COALESCE((v_contest.prize_distribution->>2)::NUMERIC, 0.1);
  END IF;

  v_prize_1 := GREATEST(ROUND(v_pool * v_share_1), 0);
  v_prize_2 := GREATEST(ROUND(v_pool * v_share_2), 0);
  v_prize_3 := GREATEST(v_pool - v_prize_1 - v_prize_2, 0);

  RETURN QUERY
  SELECT 1, v_prize_1
  UNION ALL
  SELECT 2, v_prize_2
  UNION ALL
  SELECT 3, v_prize_3;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 4. Submit / withdraw with financial audit
-- ─────────────────────────────────────────────────────────────

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

  SELECT COUNT(*) INTO v_entries_count
  FROM public.active_contest_entries
  WHERE contest_id = p_contest_id
    AND user_id = v_actor_id;

  IF v_entries_count >= COALESCE(v_contest.max_entries_per_user, 1) THEN
    RAISE EXCEPTION 'Достигнут лимит заявок';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.contest_entries
  WHERE contest_id = p_contest_id
    AND track_id = p_track_id
  LIMIT 1
  FOR UPDATE;

  IF v_existing IS NOT NULL AND COALESCE(v_existing.status, 'active') = 'active' THEN
    RETURN v_existing.id;
  END IF;

  IF v_existing IS NOT NULL THEN
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

  IF v_existing IS NULL THEN
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

CREATE OR REPLACE FUNCTION public.withdraw_contest_entry(_entry_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_contest RECORD;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
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

  IF COALESCE(v_entry.entry_fee_charged, 0) > 0 AND v_entry.entry_fee_refunded_at IS NULL THEN
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
    WHERE id = _entry_id;

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
      'Возврат взноса за отзыв заявки из конкурса "' || v_contest.title || '"',
      v_entry.id,
      'contest_entry',
      v_balance_before,
      v_balance_after,
      jsonb_build_object('contest_id', v_entry.contest_id, 'track_id', v_entry.track_id)
    );
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE VIEW public.active_contest_entries AS
SELECT *
FROM public.contest_entries
WHERE COALESCE(status, 'active') = 'active';

-- ─────────────────────────────────────────────────────────────
-- 5. Finalization and payouts
-- ─────────────────────────────────────────────────────────────

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

  CREATE TEMP TABLE tmp_contest_rankings ON COMMIT DROP AS
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
  )
  SELECT *
  FROM ranked
  WHERE place <= 3;

  SELECT COUNT(*) INTO v_winners_count FROM tmp_contest_rankings;

  IF v_winners_count > 0 THEN
    INSERT INTO public.contest_winners (
      contest_id,
      entry_id,
      user_id,
      place,
      prize_amount,
      prize_awarded
    )
    SELECT
      p_contest_id,
      r.id,
      r.user_id,
      r.place,
      COALESCE(d.prize_amount, 0),
      false
    FROM tmp_contest_rankings r
    LEFT JOIN public.get_contest_prize_distribution(p_contest_id, v_prize_pool) d
      ON d.place = r.place;

    UPDATE public.contest_entries ce
    SET rank = r.place
    FROM tmp_contest_rankings r
    WHERE ce.id = r.id;
  END IF;

  UPDATE public.contests
  SET status = 'completed',
      final_prize_pool = v_prize_pool,
      finalized_at = now()
  WHERE id = p_contest_id;

  RETURN v_winners_count;
END;
$$;

DROP FUNCTION IF EXISTS public.finalize_contest_winners(UUID);

CREATE FUNCTION public.finalize_contest_winners(_contest_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.finalize_contest(_contest_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.award_contest_prize(
  _winner_id UUID,
  _contest_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contest RECORD;
  v_winner RECORD;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT id, title
  INTO v_contest
  FROM public.contests
  WHERE id = _contest_id;

  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;

  SELECT *
  INTO v_winner
  FROM public.contest_winners
  WHERE id = _winner_id
    AND contest_id = _contest_id
  FOR UPDATE;

  IF v_winner IS NULL THEN
    RAISE EXCEPTION 'Победитель не найден';
  END IF;

  IF COALESCE(v_winner.prize_awarded, false) THEN
    RAISE EXCEPTION 'Приз уже выплачен';
  END IF;

  IF COALESCE(v_winner.prize_amount, 0) > 0 THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = v_winner.user_id
    FOR UPDATE;

    UPDATE public.profiles
    SET balance = balance + v_winner.prize_amount
    WHERE user_id = v_winner.user_id
    RETURNING balance INTO v_balance_after;

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
      v_winner.user_id,
      v_winner.prize_amount,
      'contest_prize',
      'Приз за ' || v_winner.place || ' место в конкурсе "' || v_contest.title || '"',
      v_winner.id,
      'contest_prize',
      v_balance_before,
      v_balance_after,
      jsonb_build_object('contest_id', _contest_id, 'place', v_winner.place)
    );

    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_winner.user_id,
      'prize_awarded',
      'Приз начислен',
      'На ваш баланс зачислено ' || v_winner.prize_amount || ' ₽ за ' || v_winner.place || ' место в конкурсе "' || v_contest.title || '"',
      'contest',
      _contest_id
    );
  END IF;

  UPDATE public.contest_winners
  SET prize_awarded = true,
      awarded_at = now()
  WHERE id = _winner_id;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_winner_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.prize_awarded = true AND (OLD.prize_awarded IS NULL OR OLD.prize_awarded = false) THEN
    UPDATE public.profiles
    SET contest_wins_count = COALESCE(contest_wins_count, 0) + CASE WHEN NEW.place = 1 THEN 1 ELSE 0 END,
        total_prize_won = COALESCE(total_prize_won, 0) + COALESCE(NEW.prize_amount, 0)
    WHERE user_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 6. Rating, leaderboard and achievements
-- ─────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_user_contest_rating(UUID);

CREATE FUNCTION public.get_user_contest_rating(
  p_user_id UUID
)
RETURNS TABLE (
  rating INTEGER,
  league_name TEXT,
  league_color TEXT,
  league_tier INTEGER,
  league_multiplier NUMERIC,
  season_points INTEGER,
  weekly_points INTEGER,
  daily_streak INTEGER,
  best_streak INTEGER,
  total_contests INTEGER,
  total_wins INTEGER,
  total_top3 INTEGER,
  total_votes_received INTEGER,
  global_rank INTEGER,
  achievements_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH stats AS (
    SELECT
      p.user_id,
      COALESCE(p.contest_participations, 0) AS total_contests,
      COALESCE(p.contest_wins_count, 0) AS total_wins,
      (
        SELECT COUNT(*)
        FROM public.contest_winners cw
        WHERE cw.user_id = p.user_id
      ) AS total_top3,
      (
        SELECT COUNT(*)
        FROM public.contest_votes cv
        JOIN public.contest_entries ce ON ce.id = cv.entry_id
        WHERE ce.user_id = p.user_id
          AND COALESCE(ce.status, 'active') = 'active'
      ) AS total_votes_received,
      (
        SELECT COUNT(*)
        FROM public.contest_user_achievements cua
        WHERE cua.user_id = p.user_id
      ) AS achievements_count
    FROM public.profiles p
    WHERE p.user_id IS NOT NULL
  ),
  rated AS (
    SELECT
      s.*,
      (1000 + s.total_wins * 50 + GREATEST(s.total_top3 - s.total_wins, 0) * 15 + LEAST(s.total_votes_received, 500))::INTEGER AS rating,
      (s.total_wins * 10 + s.total_top3 * 3 + s.total_contests)::INTEGER AS season_points,
      (s.total_wins * 5 + s.total_top3 * 2)::INTEGER AS weekly_points,
      0::INTEGER AS daily_streak,
      0::INTEGER AS best_streak
    FROM stats s
    WHERE s.total_contests > 0 OR s.total_top3 > 0 OR s.total_votes_received > 0
  ),
  ranked AS (
    SELECT
      r.*,
      DENSE_RANK() OVER (ORDER BY r.rating DESC, r.total_votes_received DESC, r.user_id) AS global_rank
    FROM rated r
  )
  SELECT
    r.rating,
    COALESCE(l.name, 'Бронза') AS league_name,
    COALESCE(l.color, '#cd7f32') AS league_color,
    COALESCE(l.tier, 1) AS league_tier,
    COALESCE(l.multiplier, 1.0) AS league_multiplier,
    r.season_points,
    r.weekly_points,
    r.daily_streak,
    r.best_streak,
    r.total_contests,
    r.total_wins,
    r.total_top3,
    r.total_votes_received,
    r.global_rank,
    r.achievements_count
  FROM ranked r
  LEFT JOIN LATERAL (
    SELECT name, color, tier, multiplier
    FROM public.contest_leagues l
    WHERE r.rating >= l.min_rating
      AND (l.max_rating IS NULL OR r.rating <= l.max_rating)
    ORDER BY l.tier DESC
    LIMIT 1
  ) l ON true
  WHERE r.user_id = p_user_id;
$$;

DROP FUNCTION IF EXISTS public.get_contest_leaderboard(TEXT, UUID, INTEGER);

CREATE FUNCTION public.get_contest_leaderboard(
  p_type TEXT DEFAULT 'rating',
  p_season_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  pos INTEGER,
  user_id UUID,
  username TEXT,
  avatar_url TEXT,
  rating INTEGER,
  season_points INTEGER,
  weekly_points INTEGER,
  daily_streak INTEGER,
  total_wins INTEGER,
  total_top3 INTEGER,
  league_name TEXT,
  league_color TEXT,
  league_tier INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH stats AS (
    SELECT
      p.user_id,
      COALESCE(p.username, 'Пользователь') AS username,
      p.avatar_url,
      COALESCE(p.contest_participations, 0) AS total_contests,
      COALESCE(p.contest_wins_count, 0) AS total_wins,
      (
        SELECT COUNT(*)
        FROM public.contest_winners cw
        WHERE cw.user_id = p.user_id
      ) AS total_top3,
      (
        SELECT COUNT(*)
        FROM public.contest_votes cv
        JOIN public.contest_entries ce ON ce.id = cv.entry_id
        WHERE ce.user_id = p.user_id
          AND COALESCE(ce.status, 'active') = 'active'
      ) AS total_votes_received
    FROM public.profiles p
    WHERE p.user_id IS NOT NULL
  ),
  rated AS (
    SELECT
      s.*,
      (1000 + s.total_wins * 50 + GREATEST(s.total_top3 - s.total_wins, 0) * 15 + LEAST(s.total_votes_received, 500))::INTEGER AS rating,
      (s.total_wins * 10 + s.total_top3 * 3 + s.total_contests)::INTEGER AS season_points,
      (s.total_wins * 5 + s.total_top3 * 2)::INTEGER AS weekly_points,
      0::INTEGER AS daily_streak
    FROM stats s
    WHERE s.total_contests > 0 OR s.total_top3 > 0 OR s.total_votes_received > 0
  ),
  base AS (
    SELECT
      r.*,
      COALESCE(l.name, 'Бронза') AS league_name,
      COALESCE(l.color, '#cd7f32') AS league_color,
      COALESCE(l.tier, 1) AS league_tier
    FROM rated r
    LEFT JOIN LATERAL (
      SELECT name, color, tier
      FROM public.contest_leagues l
      WHERE r.rating >= l.min_rating
        AND (l.max_rating IS NULL OR r.rating <= l.max_rating)
      ORDER BY l.tier DESC
      LIMIT 1
    ) l ON true
  ),
  ranked AS (
    SELECT
      ROW_NUMBER() OVER (
        ORDER BY
          CASE WHEN p_type = 'season' THEN season_points ELSE rating END DESC,
          CASE WHEN p_type = 'weekly' THEN weekly_points ELSE total_wins END DESC,
          CASE WHEN p_type = 'streak' THEN daily_streak ELSE total_top3 END DESC,
          total_votes_received DESC,
          user_id
      ) AS pos,
      *
    FROM base
  )
  SELECT
    pos,
    user_id,
    username,
    avatar_url,
    rating,
    season_points,
    weekly_points,
    daily_streak,
    total_wins,
    total_top3,
    league_name,
    league_color,
    league_tier
  FROM ranked
  ORDER BY pos
  LIMIT GREATEST(COALESCE(p_limit, 50), 1);
$$;

CREATE OR REPLACE FUNCTION public.check_contest_achievements(
  p_user_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats RECORD;
  v_inserted INTEGER := 0;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT
    COALESCE(contest_participations, 0) AS total_contests,
    COALESCE(contest_wins_count, 0) AS total_wins,
    (
      SELECT COUNT(*)
      FROM public.contest_winners cw
      WHERE cw.user_id = p_user_id
    ) AS total_top3
  INTO v_stats
  FROM public.profiles
  WHERE user_id = p_user_id;

  IF v_stats IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO public.contest_user_achievements (user_id, achievement_id)
  SELECT p_user_id, a.id
  FROM public.contest_achievements a
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.contest_user_achievements cua
    WHERE cua.user_id = p_user_id
      AND cua.achievement_id = a.id
  )
  AND (
    (a.condition_type = 'participations' AND v_stats.total_contests >= a.condition_value)
    OR (a.condition_type = 'wins' AND v_stats.total_wins >= a.condition_value)
    OR (a.condition_type = 'top3' AND v_stats.total_top3 >= a.condition_value)
  );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 7. Lifecycle processor
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_contest_lifecycle()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_processed INTEGER := 0;
  v_contest RECORD;
BEGIN
  IF NOT (
    public.is_admin(auth.uid())
    OR public.is_super_admin(auth.uid())
    OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
  ) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  UPDATE public.contests
  SET status = 'voting'
  WHERE status = 'active'
    AND end_date <= now();

  GET DIAGNOSTICS v_processed = ROW_COUNT;

  FOR v_contest IN
    SELECT id
    FROM public.contests
    WHERE status = 'voting'
      AND voting_end_date <= now()
      AND COALESCE(auto_finalize, true) = true
  LOOP
    PERFORM public.finalize_contest(v_contest.id);
    v_processed := v_processed + 1;
  END LOOP;

  RETURN v_processed;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 8. Grants
-- ─────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.calculate_contest_prize_pool(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contest_prize_distribution(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_contest_entry(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_contest_entry(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_contest(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_contest_winners(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_contest_prize(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_contest_rating(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contest_leaderboard(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_contest_achievements(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_contest_lifecycle() TO authenticated;
