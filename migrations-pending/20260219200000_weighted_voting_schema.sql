-- =============================================================
-- ULTIMATE VOTING ARCHITECTURE — Phase 1: Database Schema
-- Weighted votes, voter profiles, combos, audit, snapshots, chart
-- =============================================================

-- 1. weighted_votes — замена track_votes, хранит вычисленный вес каждого голоса
CREATE TABLE public.weighted_votes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  vote_type TEXT NOT NULL CHECK (vote_type IN ('like', 'dislike', 'superlike')),
  raw_weight NUMERIC NOT NULL DEFAULT 1.0 CHECK (raw_weight >= 0 AND raw_weight <= 5.0),
  fraud_multiplier NUMERIC NOT NULL DEFAULT 1.0 CHECK (fraud_multiplier >= 0 AND fraud_multiplier <= 1.0),
  combo_bonus NUMERIC NOT NULL DEFAULT 0.0 CHECK (combo_bonus >= 0 AND combo_bonus <= 0.5),
  final_weight NUMERIC NOT NULL DEFAULT 1.0,
  fingerprint_hash TEXT,
  ip_address INET,
  context JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT unique_user_track_weighted_vote UNIQUE (track_id, user_id)
);

-- 2. voter_profiles — профиль голосующего (статистика, комбо, ранг)
CREATE TABLE public.voter_profiles (
  user_id UUID NOT NULL PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  votes_cast_total INTEGER NOT NULL DEFAULT 0,
  votes_cast_30d INTEGER NOT NULL DEFAULT 0,
  correct_predictions INTEGER NOT NULL DEFAULT 0,
  accuracy_rate NUMERIC DEFAULT 0 CHECK (accuracy_rate >= 0 AND accuracy_rate <= 1),
  current_combo INTEGER NOT NULL DEFAULT 0,
  best_combo INTEGER NOT NULL DEFAULT 0,
  last_vote_at TIMESTAMP WITH TIME ZONE,
  daily_votes_today INTEGER NOT NULL DEFAULT 0,
  daily_votes_date DATE,
  voter_rank TEXT DEFAULT 'scout' CHECK (voter_rank IN ('scout', 'curator', 'tastemaker', 'oracle')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 3. vote_combos — активные комбо-серии голосований
CREATE TABLE public.vote_combos (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  combo_length INTEGER NOT NULL DEFAULT 0,
  bonus_earned NUMERIC NOT NULL DEFAULT 0,
  started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  last_vote_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  is_active BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX idx_vote_combos_user_active ON public.vote_combos(user_id, is_active) WHERE is_active = true;

-- 4. vote_audit_log — аудит всех действий с голосами
CREATE TABLE public.vote_audit_log (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vote_id UUID REFERENCES public.weighted_votes(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('cast', 'change', 'revoke', 'fraud_flag')),
  details JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_vote_audit_log_vote_id ON public.vote_audit_log(vote_id);
CREATE INDEX idx_vote_audit_log_created ON public.vote_audit_log(created_at DESC);

-- 5. voting_snapshots — снапшоты результатов (для графиков динамики)
CREATE TABLE public.voting_snapshots (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  weighted_likes NUMERIC NOT NULL DEFAULT 0,
  weighted_dislikes NUMERIC NOT NULL DEFAULT 0,
  total_voters INTEGER NOT NULL DEFAULT 0,
  approval_rate NUMERIC DEFAULT 0,
  snapshot_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_voting_snapshots_track ON public.voting_snapshots(track_id, snapshot_at DESC);

-- 6. chart_entries — глобальный чарт на основе голосов
CREATE TABLE public.chart_entries (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  previous_position INTEGER,
  chart_score NUMERIC NOT NULL DEFAULT 0,
  chart_type TEXT NOT NULL CHECK (chart_type IN ('daily', 'weekly', 'alltime')),
  chart_date DATE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(track_id, chart_type, chart_date)
);

CREATE INDEX idx_chart_entries_type_date ON public.chart_entries(chart_type, chart_date, position);

-- 7. Добавить поля в tracks
ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS weighted_likes_sum NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS weighted_dislikes_sum NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS chart_score NUMERIC,
  ADD COLUMN IF NOT EXISTS chart_position INTEGER;

-- 8. Индексы для weighted_votes (unique_user_track_weighted_vote уже создаёт индекс на track_id, user_id)
CREATE INDEX idx_weighted_votes_track_type ON public.weighted_votes(track_id, vote_type);
CREATE INDEX idx_weighted_votes_created ON public.weighted_votes(created_at);
CREATE INDEX idx_weighted_votes_fingerprint ON public.weighted_votes(fingerprint_hash, track_id) WHERE fingerprint_hash IS NOT NULL;

-- 9. Materialized view для быстрого чтения
CREATE MATERIALIZED VIEW public.mv_voting_live AS
SELECT
  wv.track_id,
  SUM(CASE WHEN wv.vote_type = 'like' THEN wv.final_weight ELSE 0 END) AS weighted_likes,
  SUM(CASE WHEN wv.vote_type = 'dislike' THEN wv.final_weight ELSE 0 END) AS weighted_dislikes,
  SUM(CASE WHEN wv.vote_type = 'superlike' THEN wv.final_weight ELSE 0 END) AS weighted_superlikes,
  COUNT(DISTINCT wv.user_id) AS total_voters
FROM public.weighted_votes wv
JOIN public.tracks t ON t.id = wv.track_id
WHERE t.moderation_status = 'voting' AND t.voting_ends_at > now()
GROUP BY wv.track_id;

CREATE UNIQUE INDEX idx_mv_voting_live_track ON public.mv_voting_live(track_id);

-- 10. RLS для новых таблиц
ALTER TABLE public.weighted_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voter_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vote_combos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vote_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voting_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chart_entries ENABLE ROW LEVEL SECURITY;

-- weighted_votes: select all, insert/update/delete own
CREATE POLICY "Anyone can view weighted votes"
  ON public.weighted_votes FOR SELECT USING (true);

CREATE POLICY "Authenticated users can vote"
  ON public.weighted_votes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own vote"
  ON public.weighted_votes FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own vote"
  ON public.weighted_votes FOR DELETE
  USING (auth.uid() = user_id);

-- voter_profiles: users see own (INSERT/UPDATE via SECURITY DEFINER RPC)
CREATE POLICY "Users can view own voter profile"
  ON public.voter_profiles FOR SELECT
  USING (auth.uid() = user_id);

-- vote_combos: users see own (INSERT/UPDATE via SECURITY DEFINER RPC)
CREATE POLICY "Users can view own vote combos"
  ON public.vote_combos FOR SELECT
  USING (auth.uid() = user_id);

-- vote_audit_log: admins can view (INSERT via SECURITY DEFINER RPC)
CREATE POLICY "Admins can view vote audit"
  ON public.vote_audit_log FOR SELECT
  USING (public.is_admin(auth.uid()));

-- voting_snapshots: public read (INSERT via SECURITY DEFINER RPC)
CREATE POLICY "Anyone can view voting snapshots"
  ON public.voting_snapshots FOR SELECT USING (true);

-- chart_entries: public read (INSERT/UPDATE via SECURITY DEFINER RPC)
CREATE POLICY "Anyone can view chart entries"
  ON public.chart_entries FOR SELECT USING (true);

-- 11. Достижения голосования
INSERT INTO public.achievements (name, name_ru, description, description_ru, icon, category, requirement_type, requirement_value, sort_order)
SELECT v.name, v.name_ru, v.description, v.description_ru, v.icon, v.category, v.requirement_type, v.requirement_value, v.sort_order
FROM (VALUES
  ('First Vote'::text, 'Первый голос', 'Cast your first vote', 'Отдайте первый голос за трек', '🗳️', 'engagement', 'votes_cast', 1, 200),
  ('Active Voter', 'Активный избиратель', 'Cast 50 votes', 'Отдайте 50 голосов', '📊', 'engagement', 'votes_cast', 50, 201),
  ('Voice of the People', 'Голос народа', 'Cast 500 votes', 'Отдайте 500 голосов', '📣', 'engagement', 'votes_cast', 500, 202),
  ('Golden Ear', 'Золотой слух', '10 correct predictions in a row', '10 правильных прогнозов подряд', '👂', 'engagement', 'correct_predictions_streak', 10, 203),
  ('Combo Master', 'Комбо-мастер', '30-day voting combo', 'Комбо 30 дней подряд', '🔥', 'engagement', 'combo_days', 30, 204),
  ('Oracle', 'Оракул', 'Reach Oracle voter rank', 'Достичь ранга Оракул', '👑', 'engagement', 'voter_rank_oracle', 1, 205)
) AS v(name, name_ru, description, description_ru, icon, category, requirement_type, requirement_value, sort_order)
WHERE NOT EXISTS (SELECT 1 FROM public.achievements a WHERE a.name = v.name AND a.requirement_type = v.requirement_type);

-- 12. Настройки голосования
INSERT INTO public.settings (key, value, description) VALUES
  ('voting_combo_window_hours', '36', 'Окно часов между голосами для сохранения комбо'),
  ('voting_superlike_cost', '50', 'Стоимость суперлайка в AiPCI'),
  ('voting_chart_update_interval', '300', 'Интервал обновления чарта в секундах (5 мин)')
ON CONFLICT (key) DO NOTHING;
