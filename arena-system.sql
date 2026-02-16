-- =====================================================
-- ARENA SYSTEM: Полная миграция конкурсной системы
-- Сезоны, лиги, рейтинги, достижения, антифрод,
-- гибридный скоринг, автоматический lifecycle
-- =====================================================

-- ═══════════════════════════════════════════════════════
-- 1. РАСШИРЕНИЕ contests: типы + автоматизация
-- ═══════════════════════════════════════════════════════
ALTER TABLE public.contests
  ADD COLUMN IF NOT EXISTS contest_type text DEFAULT 'classic',
  ADD COLUMN IF NOT EXISTS entry_fee integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS min_participants integer DEFAULT 3,
  ADD COLUMN IF NOT EXISTS min_votes_to_win integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS auto_finalize boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS season_id uuid,
  ADD COLUMN IF NOT EXISTS theme text,
  ADD COLUMN IF NOT EXISTS prize_pool_formula text DEFAULT 'fixed',
  ADD COLUMN IF NOT EXISTS prize_distribution jsonb DEFAULT '[0.6, 0.3, 0.1]'::jsonb,
  ADD COLUMN IF NOT EXISTS require_new_track boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS scoring_mode text DEFAULT 'votes',
  ADD COLUMN IF NOT EXISTS voting_end_date timestamptz,
  ADD COLUMN IF NOT EXISTS max_entries_per_user integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS jury_weight numeric(3,2) DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS jury_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS assets_url text,
  ADD COLUMN IF NOT EXISTS assets_description text,
  ADD COLUMN IF NOT EXISTS is_remix_contest boolean DEFAULT false;

-- ═══════════════════════════════════════════════════════
-- 2. СЕЗОНЫ
-- ═══════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.contest_seasons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  start_date timestamptz NOT NULL,
  end_date timestamptz NOT NULL,
  status text DEFAULT 'upcoming'
    CHECK (status IN ('upcoming', 'active', 'completed')),
  theme text,
  grand_prize_amount integer DEFAULT 0,
  grand_prize_description text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- FK сезона в contests
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'contests_season_id_fkey'
  ) THEN
    ALTER TABLE public.contests
      ADD CONSTRAINT contests_season_id_fkey
      FOREIGN KEY (season_id) REFERENCES public.contest_seasons(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════
-- 3. ЛИГИ
-- ═══════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.contest_leagues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  tier integer NOT NULL UNIQUE,
  min_rating integer NOT NULL,
  max_rating integer,
  icon_url text,
  color text,
  multiplier numeric(3,2) DEFAULT 1.0,
  created_at timestamptz DEFAULT now()
);

-- Seed лиги
INSERT INTO public.contest_leagues (name, tier, min_rating, max_rating, color, multiplier)
VALUES
  ('Бронза', 1, 0, 999, '#CD7F32', 1.0),
  ('Серебро', 2, 1000, 1499, '#C0C0C0', 1.2),
  ('Золото', 3, 1500, 1999, '#FFD700', 1.5),
  ('Платина', 4, 2000, NULL, '#E5E4E2', 2.0)
ON CONFLICT (tier) DO NOTHING;

-- ═══════════════════════════════════════════════════════
-- 4. РЕЙТИНГИ УЧАСТНИКОВ
-- ═══════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.contest_ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  rating integer DEFAULT 1000,
  league_id uuid REFERENCES public.contest_leagues(id),
  season_points integer DEFAULT 0,
  season_id uuid REFERENCES public.contest_seasons(id),
  weekly_points integer DEFAULT 0,
  daily_streak integer DEFAULT 0,
  best_streak integer DEFAULT 0,
  total_contests integer DEFAULT 0,
  total_wins integer DEFAULT 0,
  total_top3 integer DEFAULT 0,
  total_votes_received integer DEFAULT 0,
  last_contest_at timestamptz,
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contest_ratings_rating
  ON public.contest_ratings (rating DESC);
CREATE INDEX IF NOT EXISTS idx_contest_ratings_season
  ON public.contest_ratings (season_id, season_points DESC);
CREATE INDEX IF NOT EXISTS idx_contest_ratings_weekly
  ON public.contest_ratings (weekly_points DESC);

-- ═══════════════════════════════════════════════════════
-- 5. ДОСТИЖЕНИЯ
-- ═══════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.contest_achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL UNIQUE,
  name text NOT NULL,
  description text,
  icon text DEFAULT '🏆',
  xp_reward integer DEFAULT 0,
  credit_reward integer DEFAULT 0,
  rarity text DEFAULT 'common'
    CHECK (rarity IN ('common', 'rare', 'epic', 'legendary')),
  condition_type text NOT NULL,
  condition_value integer NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_user_achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  achievement_id uuid NOT NULL REFERENCES public.contest_achievements(id) ON DELETE CASCADE,
  earned_at timestamptz DEFAULT now(),
  UNIQUE(user_id, achievement_id)
);

CREATE INDEX IF NOT EXISTS idx_contest_user_achievements_user
  ON public.contest_user_achievements (user_id);

-- Seed достижения
INSERT INTO public.contest_achievements (key, name, description, icon, xp_reward, credit_reward, rarity, condition_type, condition_value) VALUES
  ('first_entry',     'Первый шаг',       'Подать первую заявку на конкурс',             '🎵', 50,   0,   'common',    'participations', 1),
  ('5_entries',       'Постоянный участник','Участвовать в 5 конкурсах',                  '🎶', 100,  5,   'common',    'participations', 5),
  ('20_entries',      'Ветеран арены',     'Участвовать в 20 конкурсах',                  '⚔️', 300,  15,  'rare',      'participations', 20),
  ('50_entries',      'Мастер арены',      'Участвовать в 50 конкурсах',                  '🏟️', 500,  30,  'epic',      'participations', 50),
  ('first_win',       'Первая победа',     'Выиграть первый конкурс',                     '🏆', 200,  10,  'rare',      'wins', 1),
  ('5_wins',          'Пятикратный чемпион','Выиграть 5 конкурсов',                       '👑', 500,  25,  'epic',      'wins', 5),
  ('20_wins',         'Легенда',           'Выиграть 20 конкурсов',                       '🌟', 2000, 100, 'legendary', 'wins', 20),
  ('first_top3',      'На пьедестале',     'Попасть в топ-3 конкурса',                    '🥉', 100,  5,   'common',    'top3', 1),
  ('10_top3',         'Призёр',            'Попасть в топ-3 десять раз',                  '🥇', 400,  20,  'rare',      'top3', 10),
  ('streak_3',        'Три дня огня',      'Участвовать 3 дня подряд',                    '🔥', 50,   3,   'common',    'streak', 3),
  ('streak_7',        'Неделя огня',       'Участвовать 7 дней подряд',                   '🔥', 200,  10,  'rare',      'streak', 7),
  ('streak_30',       'Месяц огня',        'Участвовать 30 дней подряд',                  '⭐', 1000, 50,  'epic',      'streak', 30),
  ('streak_100',      'Несгораемый',       'Участвовать 100 дней подряд',                 '💎', 5000, 200, 'legendary', 'streak', 100),
  ('votes_50',        'Голос народа',      'Получить 50 голосов суммарно',                '📣', 100,  5,   'common',    'votes_received', 50),
  ('votes_500',       'Народный любимец',  'Получить 500 голосов суммарно',               '🎤', 500,  25,  'rare',      'votes_received', 500),
  ('league_silver',   'Серебро',           'Достичь Серебряной лиги',                     '🥈', 100,  10,  'common',    'rating', 1000),
  ('league_gold',     'Золото',            'Достичь Золотой лиги',                        '🥇', 300,  25,  'rare',      'rating', 1500),
  ('league_platinum', 'Платина',           'Достичь Платиновой лиги',                     '💎', 1000, 50,  'epic',      'rating', 2000)
ON CONFLICT (key) DO NOTHING;

-- ═══════════════════════════════════════════════════════
-- 6. АНТИФРОД: расширяем contest_votes
-- ═══════════════════════════════════════════════════════
ALTER TABLE public.contest_votes
  ADD COLUMN IF NOT EXISTS ip_hash text,
  ADD COLUMN IF NOT EXISTS user_agent_hash text,
  ADD COLUMN IF NOT EXISTS is_suspicious boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS fraud_score numeric(5,2) DEFAULT 0;

-- ═══════════════════════════════════════════════════════
-- 7. ТРИГГЕР: запрет самоголосования + антибот
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.prevent_self_vote()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Запрет самоголосования
  IF EXISTS (
    SELECT 1 FROM public.contest_entries
    WHERE id = NEW.entry_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Нельзя голосовать за свою заявку';
  END IF;

  -- Аккаунт старше 24 часов
  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE user_id = NEW.user_id
      AND created_at > now() - interval '24 hours'
  ) THEN
    RAISE EXCEPTION 'Аккаунт слишком новый для голосования';
  END IF;

  -- Rate limit: 1 голос в минуту
  IF EXISTS (
    SELECT 1 FROM public.contest_votes
    WHERE user_id = NEW.user_id
      AND created_at > now() - interval '1 minute'
  ) THEN
    RAISE EXCEPTION 'Подождите минуту перед следующим голосом';
  END IF;

  -- Проверка: конкурс в фазе голосования
  IF NOT EXISTS (
    SELECT 1 FROM public.contests c
    WHERE c.id = NEW.contest_id AND c.status = 'voting'
  ) THEN
    RAISE EXCEPTION 'Голосование не открыто для этого конкурса';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_self_vote ON public.contest_votes;
CREATE TRIGGER trg_prevent_self_vote
  BEFORE INSERT ON public.contest_votes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_self_vote();

-- ═══════════════════════════════════════════════════════
-- 8. RPC: серверная подача заявки
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.submit_contest_entry(
  p_contest_id uuid,
  p_track_id uuid,
  p_user_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_contest record;
  v_entry_count integer;
  v_track record;
  v_entry_id uuid;
  v_uid uuid;
BEGIN
  v_uid := COALESCE(p_user_id, auth.uid());
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Требуется авторизация'; END IF;

  -- 1. Конкурс
  SELECT * INTO v_contest FROM public.contests WHERE id = p_contest_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Конкурс не найден'; END IF;
  IF v_contest.status != 'active' THEN RAISE EXCEPTION 'Конкурс не принимает заявки (статус: %)', v_contest.status; END IF;
  IF now() < v_contest.start_date OR now() > v_contest.end_date THEN
    RAISE EXCEPTION 'Конкурс вне временного окна подачи';
  END IF;

  -- 2. Лимит заявок
  SELECT count(*) INTO v_entry_count
  FROM public.contest_entries
  WHERE contest_id = p_contest_id AND user_id = v_uid
    AND COALESCE(status, 'active') = 'active';
  IF v_entry_count >= COALESCE(v_contest.max_entries_per_user, 1) THEN
    RAISE EXCEPTION 'Превышен лимит заявок (%)', v_contest.max_entries_per_user;
  END IF;

  -- 3. Трек
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id AND user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден или не ваш'; END IF;
  IF v_track.status != 'completed' THEN RAISE EXCEPTION 'Трек не готов (статус: %)', v_track.status; END IF;

  -- 4. Жанр
  IF v_contest.genre_id IS NOT NULL AND v_track.genre_id IS DISTINCT FROM v_contest.genre_id THEN
    RAISE EXCEPTION 'Жанр трека не совпадает с жанром конкурса';
  END IF;

  -- 5. Только новый трек (daily)
  IF COALESCE(v_contest.require_new_track, false) AND v_track.created_at < v_contest.start_date THEN
    RAISE EXCEPTION 'Нужен трек, созданный после начала конкурса';
  END IF;

  -- 6. Дубликат трека
  IF EXISTS (
    SELECT 1 FROM public.contest_entries
    WHERE contest_id = p_contest_id AND track_id = p_track_id
  ) THEN
    RAISE EXCEPTION 'Этот трек уже подан на конкурс';
  END IF;

  -- 7. Entry fee
  IF COALESCE(v_contest.entry_fee, 0) > 0 THEN
    UPDATE public.profiles
    SET balance = balance - v_contest.entry_fee
    WHERE user_id = v_uid AND balance >= v_contest.entry_fee;
    IF NOT FOUND THEN RAISE EXCEPTION 'Недостаточно кредитов (нужно: %)', v_contest.entry_fee; END IF;
  END IF;

  -- 8. Создать заявку
  INSERT INTO public.contest_entries (contest_id, track_id, user_id)
  VALUES (p_contest_id, p_track_id, v_uid)
  RETURNING id INTO v_entry_id;

  -- 9. Обновить рейтинг/стрик
  INSERT INTO public.contest_ratings (user_id, daily_streak, best_streak, last_contest_at, total_contests)
  VALUES (v_uid, 1, 1, now(), 1)
  ON CONFLICT (user_id) DO UPDATE SET
    daily_streak = CASE
      WHEN contest_ratings.last_contest_at IS NULL THEN 1
      WHEN contest_ratings.last_contest_at >= now() - interval '48 hours' THEN contest_ratings.daily_streak + 1
      ELSE 1
    END,
    best_streak = GREATEST(
      contest_ratings.best_streak,
      CASE
        WHEN contest_ratings.last_contest_at IS NULL THEN 1
        WHEN contest_ratings.last_contest_at >= now() - interval '48 hours' THEN contest_ratings.daily_streak + 1
        ELSE 1
      END
    ),
    last_contest_at = now(),
    total_contests = contest_ratings.total_contests + 1,
    updated_at = now();

  RETURN v_entry_id;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 9. RPC: гибридное определение победителей
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.finalize_contest(p_contest_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_contest record;
  v_winner record;
  v_place integer := 0;
  v_prize_pool integer;
  v_distribution jsonb;
  v_share numeric;
  v_winners_count integer := 0;
  v_max_votes integer;
  v_participant_count integer;
BEGIN
  SELECT * INTO v_contest FROM public.contests WHERE id = p_contest_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Конкурс не найден'; END IF;

  SELECT count(*) INTO v_participant_count
  FROM public.contest_entries
  WHERE contest_id = p_contest_id AND COALESCE(status, 'active') = 'active';

  -- Проверить минимум участников
  IF v_participant_count < COALESCE(v_contest.min_participants, 3) THEN
    -- Вернуть entry_fee
    IF COALESCE(v_contest.entry_fee, 0) > 0 THEN
      UPDATE public.profiles p
      SET balance = balance + v_contest.entry_fee
      FROM public.contest_entries ce
      WHERE ce.contest_id = p_contest_id
        AND ce.user_id = p.user_id
        AND COALESCE(ce.status, 'active') = 'active';
    END IF;
    UPDATE public.contests SET status = 'cancelled' WHERE id = p_contest_id;
    RETURN 0;
  END IF;

  -- Призовой фонд
  v_prize_pool := CASE COALESCE(v_contest.prize_pool_formula, 'fixed')
    WHEN 'pool' THEN
      (COALESCE(v_contest.entry_fee, 0) * v_participant_count * 0.8)::integer
    WHEN 'dynamic' THEN
      COALESCE(v_contest.prize_amount, 0) + (ln(GREATEST(v_participant_count, 1)::numeric) * 100)::integer
    ELSE
      COALESCE(v_contest.prize_amount, 0)
  END;

  v_distribution := COALESCE(v_contest.prize_distribution, '[0.6, 0.3, 0.1]'::jsonb);

  -- Удалить старых победителей
  DELETE FROM public.contest_winners WHERE contest_id = p_contest_id;

  -- Макс голосов для нормализации
  SELECT COALESCE(max(votes_count), 0) INTO v_max_votes
  FROM public.contest_entries
  WHERE contest_id = p_contest_id AND COALESCE(status, 'active') = 'active';

  -- Итерация по лидерам
  FOR v_winner IN
    SELECT
      ce.id as entry_id,
      ce.user_id,
      ce.votes_count,
      CASE COALESCE(v_contest.scoring_mode, 'votes')
        WHEN 'votes' THEN
          ce.votes_count::numeric
        WHEN 'jury' THEN
          COALESCE(
            (SELECT avg((js.technique_score + js.creativity_score +
                         js.production_score + js.overall_score) / 4.0)
             FROM public.contest_jury_scores js WHERE js.entry_id = ce.id),
            0
          ) * 10
        WHEN 'hybrid' THEN
          (CASE WHEN v_max_votes > 0
                THEN (ce.votes_count::numeric / v_max_votes) * 10
                ELSE 0 END) * (1 - COALESCE(v_contest.jury_weight, 0.5))
          +
          COALESCE(
            (SELECT avg((js.technique_score + js.creativity_score +
                         js.production_score + js.overall_score) / 4.0)
             FROM public.contest_jury_scores js WHERE js.entry_id = ce.id),
            0
          ) * COALESCE(v_contest.jury_weight, 0.5)
        ELSE ce.votes_count::numeric
      END as final_score
    FROM public.contest_entries ce
    WHERE ce.contest_id = p_contest_id
      AND COALESCE(ce.status, 'active') = 'active'
      AND ce.votes_count >= COALESCE(v_contest.min_votes_to_win, 0)
    ORDER BY final_score DESC, ce.created_at ASC
    LIMIT jsonb_array_length(v_distribution)
  LOOP
    v_place := v_place + 1;
    v_share := COALESCE((v_distribution->>(v_place - 1))::numeric, 0);

    INSERT INTO public.contest_winners (contest_id, entry_id, user_id, place)
    VALUES (p_contest_id, v_winner.entry_id, v_winner.user_id, v_place);

    -- Начислить приз
    IF v_prize_pool > 0 AND v_share > 0 THEN
      UPDATE public.profiles
      SET balance = balance + (v_prize_pool * v_share)::integer
      WHERE user_id = v_winner.user_id;

      UPDATE public.contest_winners
      SET prize_awarded = true
      WHERE contest_id = p_contest_id AND place = v_place;
    END IF;

    -- Обновить рейтинг
    UPDATE public.contest_ratings
    SET rating = rating + CASE v_place WHEN 1 THEN 50 WHEN 2 THEN 25 WHEN 3 THEN 10 ELSE 5 END,
        season_points = season_points + CASE v_place WHEN 1 THEN 100 WHEN 2 THEN 60 WHEN 3 THEN 30 ELSE 10 END,
        total_wins = total_wins + CASE WHEN v_place = 1 THEN 1 ELSE 0 END,
        total_top3 = total_top3 + 1,
        updated_at = now()
    WHERE user_id = v_winner.user_id;

    UPDATE public.contest_entries SET rank = v_place WHERE id = v_winner.entry_id;
    v_winners_count := v_winners_count + 1;
  END LOOP;

  -- Все участники без приза получают -5 рейтинга (потеря при проигрыше, мотивирует расти)
  UPDATE public.contest_ratings cr
  SET rating = GREATEST(rating - 5, 0), updated_at = now()
  FROM public.contest_entries ce
  WHERE ce.contest_id = p_contest_id
    AND ce.user_id = cr.user_id
    AND COALESCE(ce.status, 'active') = 'active'
    AND NOT EXISTS (
      SELECT 1 FROM public.contest_winners cw
      WHERE cw.contest_id = p_contest_id AND cw.user_id = ce.user_id
    );

  -- Обновить лиги для всех участников
  UPDATE public.contest_ratings cr
  SET league_id = (
    SELECT cl.id FROM public.contest_leagues cl
    WHERE cr.rating >= cl.min_rating
      AND (cl.max_rating IS NULL OR cr.rating <= cl.max_rating)
    ORDER BY cl.tier DESC LIMIT 1
  )
  FROM public.contest_entries ce
  WHERE ce.contest_id = p_contest_id AND ce.user_id = cr.user_id;

  UPDATE public.contests SET status = 'completed' WHERE id = p_contest_id;
  RETURN v_winners_count;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 10. RPC: автоматический lifecycle
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.process_contest_lifecycle()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_processed integer := 0;
  v_contest record;
BEGIN
  -- active → voting
  FOR v_contest IN
    SELECT id FROM public.contests
    WHERE status = 'active' AND end_date <= now()
  LOOP
    UPDATE public.contests SET status = 'voting' WHERE id = v_contest.id;
    v_processed := v_processed + 1;
  END LOOP;

  -- voting → completed (auto_finalize)
  FOR v_contest IN
    SELECT id FROM public.contests
    WHERE status = 'voting'
      AND voting_end_date <= now()
      AND COALESCE(auto_finalize, true) = true
  LOOP
    PERFORM public.finalize_contest(v_contest.id);
    v_processed := v_processed + 1;
  END LOOP;

  -- Сезоны
  UPDATE public.contest_seasons SET status = 'active'
  WHERE status = 'upcoming' AND start_date <= now();

  UPDATE public.contest_seasons SET status = 'completed'
  WHERE status = 'active' AND end_date <= now();

  RETURN v_processed;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 11. RPC: проверка и начисление достижений
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.check_contest_achievements(p_user_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_rating record;
  v_ach record;
  v_awarded integer := 0;
  v_val integer;
BEGIN
  SELECT * INTO v_rating FROM public.contest_ratings WHERE user_id = p_user_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  FOR v_ach IN SELECT * FROM public.contest_achievements LOOP
    -- Уже получено?
    IF EXISTS (
      SELECT 1 FROM public.contest_user_achievements
      WHERE user_id = p_user_id AND achievement_id = v_ach.id
    ) THEN CONTINUE; END IF;

    -- Проверить условие
    v_val := CASE v_ach.condition_type
      WHEN 'participations' THEN v_rating.total_contests
      WHEN 'wins'           THEN v_rating.total_wins
      WHEN 'top3'           THEN v_rating.total_top3
      WHEN 'streak'         THEN v_rating.best_streak
      WHEN 'votes_received' THEN v_rating.total_votes_received
      WHEN 'rating'         THEN v_rating.rating
      ELSE 0
    END;

    IF v_val >= v_ach.condition_value THEN
      INSERT INTO public.contest_user_achievements (user_id, achievement_id)
      VALUES (p_user_id, v_ach.id)
      ON CONFLICT DO NOTHING;

      -- Начислить XP
      IF v_ach.xp_reward > 0 THEN
        UPDATE public.profiles SET xp = COALESCE(xp, 0) + v_ach.xp_reward WHERE user_id = p_user_id;
      END IF;

      -- Начислить кредиты
      IF v_ach.credit_reward > 0 THEN
        UPDATE public.profiles SET balance = COALESCE(balance, 0) + v_ach.credit_reward WHERE user_id = p_user_id;
      END IF;

      -- Уведомление
      INSERT INTO public.notifications (user_id, type, title, message)
      VALUES (p_user_id, 'achievement', 'Достижение: ' || v_ach.name,
              v_ach.icon || ' ' || v_ach.description)
      ON CONFLICT DO NOTHING;

      v_awarded := v_awarded + 1;
    END IF;
  END LOOP;

  RETURN v_awarded;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 12. RPC: лидерборд
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_contest_leaderboard(
  p_type text DEFAULT 'rating',
  p_season_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  pos bigint,
  user_id uuid,
  username text,
  avatar_url text,
  rating integer,
  season_points integer,
  weekly_points integer,
  daily_streak integer,
  total_wins integer,
  total_top3 integer,
  league_name text,
  league_color text,
  league_tier integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
BEGIN
  RETURN QUERY
  SELECT
    row_number() OVER (ORDER BY
      CASE p_type
        WHEN 'rating' THEN cr.rating
        WHEN 'season' THEN cr.season_points
        WHEN 'weekly' THEN cr.weekly_points
        WHEN 'streak' THEN cr.daily_streak
        ELSE cr.rating
      END DESC
    ) as pos,
    cr.user_id,
    COALESCE(p.display_name, p.username, 'Аноним') as username,
    p.avatar_url,
    cr.rating,
    cr.season_points,
    cr.weekly_points,
    cr.daily_streak,
    cr.total_wins,
    cr.total_top3,
    cl.name as league_name,
    cl.color as league_color,
    COALESCE(cl.tier, 1) as league_tier
  FROM public.contest_ratings cr
  LEFT JOIN public.profiles p ON p.user_id = cr.user_id
  LEFT JOIN public.contest_leagues cl ON cl.id = cr.league_id
  WHERE (p_season_id IS NULL OR cr.season_id = p_season_id)
  ORDER BY
    CASE p_type
      WHEN 'rating' THEN cr.rating
      WHEN 'season' THEN cr.season_points
      WHEN 'weekly' THEN cr.weekly_points
      WHEN 'streak' THEN cr.daily_streak
      ELSE cr.rating
    END DESC
  LIMIT p_limit;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 13. RPC: данные рейтинга пользователя
-- ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_user_contest_rating(p_user_id uuid)
RETURNS TABLE(
  rating integer,
  league_name text,
  league_color text,
  league_tier integer,
  league_multiplier numeric,
  season_points integer,
  weekly_points integer,
  daily_streak integer,
  best_streak integer,
  total_contests integer,
  total_wins integer,
  total_top3 integer,
  total_votes_received integer,
  global_rank bigint,
  achievements_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(cr.rating, 1000),
    COALESCE(cl.name, 'Бронза'),
    COALESCE(cl.color, '#CD7F32'),
    COALESCE(cl.tier, 1),
    COALESCE(cl.multiplier, 1.0),
    COALESCE(cr.season_points, 0),
    COALESCE(cr.weekly_points, 0),
    COALESCE(cr.daily_streak, 0),
    COALESCE(cr.best_streak, 0),
    COALESCE(cr.total_contests, 0),
    COALESCE(cr.total_wins, 0),
    COALESCE(cr.total_top3, 0),
    COALESCE(cr.total_votes_received, 0),
    COALESCE(
      (SELECT count(*) + 1 FROM public.contest_ratings cr2 WHERE cr2.rating > COALESCE(cr.rating, 1000)),
      1
    ),
    (SELECT count(*) FROM public.contest_user_achievements cua WHERE cua.user_id = p_user_id)
  FROM public.contest_ratings cr
  LEFT JOIN public.contest_leagues cl ON cl.id = cr.league_id
  WHERE cr.user_id = p_user_id;

  -- Если нет записи — вернуть дефолты
  IF NOT FOUND THEN
    RETURN QUERY SELECT
      1000, 'Бронза'::text, '#CD7F32'::text, 1, 1.0::numeric,
      0, 0, 0, 0, 0, 0, 0, 0, 1::bigint, 0::bigint;
  END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════
-- 14. RLS для новых таблиц
-- ═══════════════════════════════════════════════════════
ALTER TABLE public.contest_seasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_leagues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_user_achievements ENABLE ROW LEVEL SECURITY;

-- Все могут читать
DROP POLICY IF EXISTS "Anyone can view seasons" ON public.contest_seasons;
CREATE POLICY "Anyone can view seasons" ON public.contest_seasons FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can view leagues" ON public.contest_leagues;
CREATE POLICY "Anyone can view leagues" ON public.contest_leagues FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can view ratings" ON public.contest_ratings;
CREATE POLICY "Anyone can view ratings" ON public.contest_ratings FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can view achievements" ON public.contest_achievements;
CREATE POLICY "Anyone can view achievements" ON public.contest_achievements FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can view user achievements" ON public.contest_user_achievements;
CREATE POLICY "Anyone can view user achievements" ON public.contest_user_achievements FOR SELECT USING (true);

-- Обновить голоса триггером при голосовании
CREATE OR REPLACE FUNCTION public.update_total_votes_received()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_entry_user_id uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT user_id INTO v_entry_user_id FROM public.contest_entries WHERE id = NEW.entry_id;
    UPDATE public.contest_ratings SET total_votes_received = total_votes_received + 1
    WHERE user_id = v_entry_user_id;
  ELSIF TG_OP = 'DELETE' THEN
    SELECT user_id INTO v_entry_user_id FROM public.contest_entries WHERE id = OLD.entry_id;
    UPDATE public.contest_ratings SET total_votes_received = GREATEST(total_votes_received - 1, 0)
    WHERE user_id = v_entry_user_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_update_total_votes ON public.contest_votes;
CREATE TRIGGER trg_update_total_votes
  AFTER INSERT OR DELETE ON public.contest_votes
  FOR EACH ROW EXECUTE FUNCTION public.update_total_votes_received();

-- Триггер: проверка достижений после финализации
CREATE OR REPLACE FUNCTION public.check_achievements_after_finalize()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    -- Проверить достижения для всех участников
    PERFORM public.check_contest_achievements(ce.user_id)
    FROM public.contest_entries ce
    WHERE ce.contest_id = NEW.id AND COALESCE(ce.status, 'active') = 'active';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_achievements ON public.contests;
CREATE TRIGGER trg_check_achievements
  AFTER UPDATE ON public.contests
  FOR EACH ROW EXECUTE FUNCTION public.check_achievements_after_finalize();

-- Конец миграции Arena System
