
-- ============================================================
-- SHIELD v2 + RESONANCE — Master Migration (Fixed)
-- ============================================================

-- ============================================================
-- PHASE 1: SHIELD v2
-- ============================================================

-- 1.1 Warning Points
CREATE TABLE public.forum_warning_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,
  total_points INTEGER NOT NULL DEFAULT 0,
  last_decay_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.forum_warning_points ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own warning points"
  ON public.forum_warning_points FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.2 Staff Notes
CREATE TABLE public.forum_staff_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  author_id UUID NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_staff_notes_user ON public.forum_staff_notes(user_id);
ALTER TABLE public.forum_staff_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Only moderators/admins can manage staff notes"
  ON public.forum_staff_notes FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.3 Warning Appeals
CREATE TABLE public.forum_warning_appeals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warning_id UUID NOT NULL REFERENCES public.forum_warnings(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  message TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  moderator_response TEXT,
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_appeals_status ON public.forum_warning_appeals(status);
CREATE INDEX idx_appeals_user ON public.forum_warning_appeals(user_id);
ALTER TABLE public.forum_warning_appeals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can create own appeals" ON public.forum_warning_appeals FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users and moderators can view appeals" ON public.forum_warning_appeals FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can update appeals" ON public.forum_warning_appeals FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.4 User Bans (3 zones)
CREATE TABLE public.forum_user_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  ban_zone TEXT NOT NULL DEFAULT 'forum',
  reason TEXT,
  banned_by UUID,
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  cooldown_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_user_bans_active ON public.forum_user_bans(user_id, ban_zone, is_active);
ALTER TABLE public.forum_user_bans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own bans" ON public.forum_user_bans FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can manage bans" ON public.forum_user_bans FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can update bans" ON public.forum_user_bans FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.5 Shield settings
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('warning_points_notice', '1', 'Очки за notice'),
  ('warning_points_warning', '2', 'Очки за warning'),
  ('warning_points_silence', '3', 'Очки за silence'),
  ('warning_points_final_warning', '4', 'Очки за final_warning'),
  ('warning_points_auto_mute_24h', '3', 'Порог автомута 24ч'),
  ('warning_points_auto_mute_7d', '6', 'Порог автомута 7д'),
  ('warning_points_auto_ban', '10', 'Порог автобана форума'),
  ('warning_points_decay_days', '30', 'Дней для затухания -1 очка'),
  ('ai_auto_strike_threshold', '3', 'Скрытий AI для auto-strike'),
  ('ai_auto_strike_window_days', '7', 'Окно подсчёта скрытий AI (дней)'),
  ('post_ban_cooldown_days', '7', 'Cooldown после разбана (дней)'),
  ('warning_rep_penalty_warning', '-50', 'Штраф XP за warning'),
  ('warning_rep_penalty_final', '-150', 'Штраф XP за final_warning'),
  ('warning_rep_penalty_ban', '-9999', 'Сброс XP при бане')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- PHASE 2: RESONANCE
-- ============================================================

-- 2.1 Extend forum_user_stats
ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS xp_total INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_forum INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_music INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_social INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_earned INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_date DATE DEFAULT CURRENT_DATE,
  ADD COLUMN IF NOT EXISTS featured_badges TEXT[] DEFAULT '{}';

-- 2.2 Resonance settings
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('xp_daily_cap', '100', 'Макс XP в день'),
  ('xp_forum_topic', '3', 'XP за создание темы'),
  ('xp_forum_post', '1', 'XP за пост'),
  ('xp_forum_upvote', '5', 'XP за получение апвоута'),
  ('xp_forum_solution', '15', 'XP за решение'),
  ('xp_forum_downvote', '-2', 'XP за получение даунвоута'),
  ('xp_track_publish', '5', 'XP за публикацию трека'),
  ('xp_track_like', '2', 'XP за лайк трека'),
  ('xp_track_listen', '0', 'XP за прослушивание (отключено — нет таблицы)'),
  ('xp_follower', '3', 'XP за подписчика'),
  ('xp_comment', '1', 'XP за комментарий'),
  ('xp_comment_like', '2', 'XP за лайк комментария'),
  ('xp_contest_win', '50', 'XP за победу в конкурсе'),
  ('xp_contest_participate', '10', 'XP за участие в конкурсе'),
  ('tl1_threshold', '20', 'Порог XP для TL1'),
  ('tl2_threshold', '100', 'Порог XP для TL2'),
  ('tl3_threshold', '300', 'Порог XP для TL3'),
  ('tl4_threshold', '750', 'Порог XP для TL4'),
  ('tl_inactivity_days', '60', 'Дней неактивности для понижения TL'),
  ('tl3_clean_days', '90', 'Дней без warning для TL3')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- CORE FUNCTIONS
-- ============================================================

-- fn_add_xp: Central XP function
CREATE OR REPLACE FUNCTION public.fn_add_xp(
  p_user_id UUID, p_amount NUMERIC, p_category TEXT DEFAULT 'forum'
) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_daily_cap INTEGER; v_current_daily INTEGER; v_actual_amount INTEGER; v_new_total INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_daily_cap'), 100) INTO v_daily_cap;
  INSERT INTO forum_user_stats (user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
  UPDATE forum_user_stats SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
    WHERE user_id = p_user_id AND (xp_daily_date IS NULL OR xp_daily_date < CURRENT_DATE);
  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily FROM forum_user_stats WHERE user_id = p_user_id;
  IF p_amount > 0 THEN
    v_actual_amount := LEAST(p_amount::integer, v_daily_cap - v_current_daily);
    IF v_actual_amount <= 0 THEN RETURN 0; END IF;
  ELSE
    v_actual_amount := p_amount::integer;
  END IF;
  UPDATE forum_user_stats SET
    xp_total = GREATEST(0, xp_total + v_actual_amount),
    xp_daily_earned = CASE WHEN v_actual_amount > 0 THEN xp_daily_earned + v_actual_amount ELSE xp_daily_earned END,
    xp_forum = CASE WHEN p_category = 'forum' THEN GREATEST(0, xp_forum + v_actual_amount) ELSE xp_forum END,
    xp_music = CASE WHEN p_category = 'music' THEN GREATEST(0, xp_music + v_actual_amount) ELSE xp_music END,
    xp_social = CASE WHEN p_category = 'social' THEN GREATEST(0, xp_social + v_actual_amount) ELSE xp_social END,
    updated_at = now()
  WHERE user_id = p_user_id RETURNING xp_total INTO v_new_total;
  PERFORM fn_recalculate_trust_level(p_user_id);
  RETURN COALESCE(v_actual_amount, 0);
END; $$;

-- fn_recalculate_trust_level
CREATE OR REPLACE FUNCTION public.fn_recalculate_trust_level(p_user_id UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_xp INTEGER; v_tl1 INTEGER; v_tl2 INTEGER; v_tl3 INTEGER; v_tl4 INTEGER;
  v_new_tl INTEGER := 0; v_days INTEGER; v_has_warning BOOLEAN; v_clean_days INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl1_threshold'), 20) INTO v_tl1;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl2_threshold'), 100) INTO v_tl2;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl3_threshold'), 300) INTO v_tl3;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl4_threshold'), 750) INTO v_tl4;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl3_clean_days'), 90) INTO v_clean_days;
  SELECT xp_total INTO v_xp FROM forum_user_stats WHERE user_id = p_user_id;
  IF v_xp IS NULL THEN RETURN 0; END IF;
  SELECT COALESCE(EXTRACT(DAY FROM now() - created_at)::integer, 0) INTO v_days FROM profiles WHERE user_id = p_user_id;
  SELECT EXISTS(SELECT 1 FROM forum_warnings WHERE user_id = p_user_id AND is_active = true AND severity IN ('warning','final_warning','silence','ban') AND created_at > now() - (v_clean_days || ' days')::interval) INTO v_has_warning;
  IF v_xp >= v_tl4 AND v_days >= 60 AND NOT v_has_warning THEN v_new_tl := 4;
  ELSIF v_xp >= v_tl3 AND v_days >= 30 AND NOT v_has_warning THEN v_new_tl := 3;
  ELSIF v_xp >= v_tl2 AND v_days >= 14 THEN v_new_tl := 2;
  ELSIF v_xp >= v_tl1 AND v_days >= 3 THEN v_new_tl := 1;
  ELSE v_new_tl := 0; END IF;
  UPDATE forum_user_stats SET trust_level = v_new_tl, updated_at = now() WHERE user_id = p_user_id;
  RETURN v_new_tl;
END; $$;

-- fn_apply_warning_points trigger
CREATE OR REPLACE FUNCTION public.fn_apply_warning_points()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_points INTEGER := 0; v_total_points INTEGER; v_threshold_24h INTEGER; v_threshold_7d INTEGER; v_threshold_ban INTEGER; v_xp_penalty INTEGER := 0; v_cooldown_days INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_' || NEW.severity), 0) INTO v_points;
  IF NEW.severity = 'warning' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_warning'), -50) INTO v_xp_penalty;
  ELSIF NEW.severity = 'final_warning' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_final'), -150) INTO v_xp_penalty;
  ELSIF NEW.severity = 'ban' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_ban'), -9999) INTO v_xp_penalty;
  END IF;
  INSERT INTO forum_warning_points (user_id, total_points) VALUES (NEW.user_id, v_points) ON CONFLICT (user_id) DO UPDATE SET total_points = forum_warning_points.total_points + v_points, updated_at = now();
  SELECT total_points INTO v_total_points FROM forum_warning_points WHERE user_id = NEW.user_id;
  IF v_xp_penalty <> 0 THEN PERFORM fn_add_xp(NEW.user_id, v_xp_penalty, 'forum'); END IF;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_mute_24h'), 3) INTO v_threshold_24h;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_mute_7d'), 6) INTO v_threshold_7d;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_ban'), 10) INTO v_threshold_ban;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'post_ban_cooldown_days'), 7) INTO v_cooldown_days;
  IF NEW.severity = 'ban' OR v_total_points >= v_threshold_ban THEN
    INSERT INTO forum_user_bans (user_id, ban_zone, reason, banned_by, is_active, cooldown_until) VALUES (NEW.user_id, 'forum', 'Автобан: ' || v_total_points || ' очков', NEW.issued_by, true, now() + (v_cooldown_days || ' days')::interval);
    UPDATE forum_user_stats SET is_banned = true, ban_reason = 'Автобан: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
  ELSIF v_total_points >= v_threshold_7d THEN
    UPDATE forum_user_stats SET is_silenced = true, silenced_until = now() + interval '7 days', silence_reason = 'Автомут: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
    UPDATE forum_user_stats SET trust_level = 0 WHERE user_id = NEW.user_id;
  ELSIF v_total_points >= v_threshold_24h THEN
    UPDATE forum_user_stats SET is_silenced = true, silenced_until = now() + interval '24 hours', silence_reason = 'Автомут: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
    UPDATE forum_user_stats SET trust_level = GREATEST(0, trust_level - 1) WHERE user_id = NEW.user_id;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_apply_warning_points AFTER INSERT ON public.forum_warnings FOR EACH ROW EXECUTE FUNCTION public.fn_apply_warning_points();

-- fn_decay_warning_points
CREATE OR REPLACE FUNCTION public.fn_decay_warning_points()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_decay_days INTEGER; v_decayed INTEGER := 0;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_decay_days'), 30) INTO v_decay_days;
  UPDATE forum_warning_points SET total_points = GREATEST(0, total_points - 1), last_decay_at = now(), updated_at = now()
    WHERE total_points > 0 AND last_decay_at < now() - (v_decay_days || ' days')::interval;
  GET DIAGNOSTICS v_decayed = ROW_COUNT;
  RETURN v_decayed;
END; $$;

-- fn_check_ai_auto_strike
CREATE OR REPLACE FUNCTION public.fn_check_ai_auto_strike(p_user_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_threshold INTEGER; v_window INTEGER; v_count INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'ai_auto_strike_threshold'), 3) INTO v_threshold;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'ai_auto_strike_window_days'), 7) INTO v_window;
  SELECT COUNT(*) INTO v_count FROM forum_mod_logs WHERE target_type = 'post' AND action = 'automod_hide' AND (details->>'user_id')::uuid = p_user_id AND created_at > now() - (v_window || ' days')::interval;
  IF v_count >= v_threshold THEN
    INSERT INTO forum_warnings (user_id, issued_by, reason, severity, is_active) VALUES (p_user_id, '00000000-0000-0000-0000-000000000000', 'Систематические нарушения (AI): ' || v_count || ' скрытий за ' || v_window || ' дней', 'warning', true);
    RETURN true;
  END IF;
  RETURN false;
END; $$;

-- ============================================================
-- XP TRIGGERS
-- ============================================================

-- Forum post → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_post() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000' THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_post'), 1), 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_post AFTER INSERT ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_post();

-- Forum topic → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_topic() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000' THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_topic'), 3), 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_topic AFTER INSERT ON public.forum_topics FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_topic();

-- Forum reaction → +/- XP to post author
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_reaction() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_author UUID; v_amount INTEGER;
BEGIN
  SELECT user_id INTO v_author FROM forum_posts WHERE id = NEW.post_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;
  IF NEW.reaction_type = 'upvote' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_upvote'), 5) INTO v_amount;
  ELSIF NEW.reaction_type = 'downvote' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_downvote'), -2) INTO v_amount;
  ELSE RETURN NEW; END IF;
  PERFORM fn_add_xp(v_author, v_amount, 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_reaction AFTER INSERT ON public.forum_post_reactions FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_reaction();

-- Track published → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_publish() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.is_public = true AND (OLD IS NULL OR OLD.is_public = false) THEN
    PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_track_publish'), 5), 'music');
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_publish AFTER INSERT OR UPDATE OF is_public ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_publish();

-- Track liked → +XP to owner
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_like() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM tracks WHERE id = NEW.track_id;
  IF v_owner IS NULL OR v_owner = NEW.user_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(v_owner, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_track_like'), 2), 'music');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_like AFTER INSERT ON public.track_likes FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_like();

-- Follow → +XP to followed
CREATE OR REPLACE FUNCTION public.fn_xp_on_follow() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.following_id = NEW.follower_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.following_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_follower'), 3), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_follow AFTER INSERT ON public.user_follows FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_follow();

-- Track comment → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_comment() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_comment'), 1), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_comment AFTER INSERT ON public.track_comments FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_comment();

-- Comment liked → +XP to author
CREATE OR REPLACE FUNCTION public.fn_xp_on_comment_like() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_author UUID;
BEGIN
  SELECT user_id INTO v_author FROM track_comments WHERE id = NEW.comment_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(v_author, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_comment_like'), 2), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_comment_like AFTER INSERT ON public.comment_likes FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_comment_like();

-- Contest entry → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_contest_entry() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_contest_participate'), 10), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_contest_entry AFTER INSERT ON public.contest_entries FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_contest_entry();

-- Contest win → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_contest_win() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_contest_win'), 50), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_contest_win AFTER INSERT ON public.contest_winners FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_contest_win();

-- ============================================================
-- NEW BADGES
-- ============================================================
INSERT INTO public.achievements (name, name_ru, description, description_ru, icon, category, requirement_type, requirement_value, sort_order) VALUES
  ('First Track', 'Первый трек', 'Published your first track', 'Опубликовал первый трек', '🎵', 'music', 'tracks_published', 1, 100),
  ('Hitmaker', 'Хитмейкер', '100+ likes on a single track', '100+ лайков на одном треке', '🔥', 'music', 'track_max_likes', 100, 101),
  ('Forum Activist', 'Активист', '50+ forum posts', '50+ постов на форуме', '💬', 'forum', 'forum_posts', 50, 102),
  ('Champion', 'Чемпион', 'Won a contest', 'Победа в конкурсе', '🏆', 'contests', 'contest_wins', 1, 103),
  ('Rising Star', 'Звезда', '500+ XP', '500+ XP репутации', '⭐', 'reputation', 'xp_total', 500, 104),
  ('Expert', 'Эксперт', '10 solutions on forum', '10 ответов отмечены решением', '🎯', 'forum', 'forum_solutions', 10, 105),
  ('Influencer', 'Лидер мнений', '50+ followers', '50+ подписчиков', '👥', 'social', 'followers_count', 50, 106),
  ('Spotless', 'Безупречный', 'TL3+ no warnings 6mo', 'TL3+ без предупреждений 6 мес', '🛡️', 'reputation', 'clean_record_months', 6, 107),
  ('Veteran', 'Ветеран', '1 year on platform', '1 год на платформе', '📅', 'general', 'days_on_platform', 365, 108),
  ('Music Lover', 'Меломан', '1000+ listens given', '1000+ прослушиваний', '🎧', 'music', 'listens_given', 1000, 109),
  ('Contestant', 'Конкурсант', '5+ contest entries', '5+ участий в конкурсах', '🏅', 'contests', 'contest_entries', 5, 110),
  ('Producer', 'Продюсер', '50+ published tracks', '50+ треков', '💎', 'music', 'tracks_published', 50, 111)
ON CONFLICT DO NOTHING;
