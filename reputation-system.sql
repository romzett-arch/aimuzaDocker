-- =====================================================
-- REPUTATION & ACHIEVEMENT SYSTEM — Unified Architecture
-- Объединённая система репутации, XP, достижений и званий
-- =====================================================

-- ─── 1. Расширяем forum_user_stats новыми полями ────────

ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS xp_total INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_forum INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_music INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_social INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_earned INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_date DATE DEFAULT CURRENT_DATE,
  ADD COLUMN IF NOT EXISTS featured_badges UUID[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS hide_forum_activity BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS hide_online_status BOOLEAN DEFAULT false,
  -- Новые поля для unified reputation
  ADD COLUMN IF NOT EXISTS tier TEXT DEFAULT 'newcomer',
  ADD COLUMN IF NOT EXISTS tier_progress INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS vote_weight NUMERIC(3,2) DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS curator_score INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quality_ratio NUMERIC(4,3) DEFAULT 0.0,
  ADD COLUMN IF NOT EXISTS tracks_published INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tracks_liked_received INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS guides_published INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS collaborations_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_play_time_seconds BIGINT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS streak_days INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS best_streak INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_activity_date DATE;

-- ─── 2. Unified achievements table ─────────────────────

CREATE TABLE IF NOT EXISTS public.achievements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  description_ru TEXT,
  icon TEXT NOT NULL DEFAULT '🏆',
  category TEXT NOT NULL DEFAULT 'general'
    CHECK (category IN ('forum', 'music', 'social', 'contest', 'creator', 'general')),
  rarity TEXT NOT NULL DEFAULT 'common'
    CHECK (rarity IN ('common', 'rare', 'epic', 'legendary')),
  requirement_type TEXT NOT NULL DEFAULT 'manual',
  requirement_value INTEGER DEFAULT 1,
  xp_reward INTEGER DEFAULT 0,
  credit_reward INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_achievements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  achievement_id UUID NOT NULL REFERENCES public.achievements(id) ON DELETE CASCADE,
  earned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, achievement_id)
);

CREATE INDEX IF NOT EXISTS idx_user_achievements_user ON public.user_achievements(user_id);
CREATE INDEX IF NOT EXISTS idx_user_achievements_achievement ON public.user_achievements(achievement_id);

-- ─── 3. Reputation events log ───────────────────────────

CREATE TABLE IF NOT EXISTS public.reputation_events (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  xp_delta INTEGER DEFAULT 0,
  reputation_delta INTEGER DEFAULT 0,
  category TEXT NOT NULL DEFAULT 'general'
    CHECK (category IN ('forum', 'music', 'social', 'contest', 'creator', 'general')),
  source_type TEXT,
  source_id UUID,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reputation_events_user ON public.reputation_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reputation_events_type ON public.reputation_events(event_type);

-- ─── 4. Tier definitions ────────────────────────────────

CREATE TABLE IF NOT EXISTS public.reputation_tiers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  name_ru TEXT NOT NULL,
  name_en TEXT NOT NULL,
  level INTEGER NOT NULL UNIQUE,
  min_xp INTEGER NOT NULL DEFAULT 0,
  icon TEXT NOT NULL DEFAULT '🎵',
  color TEXT NOT NULL DEFAULT '#888888',
  gradient TEXT,
  vote_weight NUMERIC(3,2) NOT NULL DEFAULT 1.0,
  perks JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed tiers
INSERT INTO public.reputation_tiers (key, name_ru, name_en, level, min_xp, icon, color, gradient, vote_weight, perks)
VALUES
  ('newcomer',       'Новичок',          'Newcomer',        0,     0, '🎵', '#6B7280', 'from-gray-500/15 to-gray-500/5',     1.0,  '{"daily_generations": 5}'),
  ('beat_maker',     'Битмейкер',        'Beat Maker',      1,    50, '🎹', '#3B82F6', 'from-blue-500/15 to-blue-500/5',     1.2,  '{"daily_generations": 10, "can_vote": true}'),
  ('sound_designer', 'Саунд-дизайнер',   'Sound Designer',  2,   200, '🎛️', '#10B981', 'from-emerald-500/15 to-emerald-500/5', 1.5, '{"daily_generations": 15, "can_vote": true, "can_curate": true}'),
  ('producer',       'Продюсер',         'Producer',        3,   500, '🎧', '#F59E0B', 'from-amber-500/15 to-amber-500/5',   2.0,  '{"daily_generations": 25, "can_vote": true, "can_curate": true, "vote_highlight": true}'),
  ('maestro',        'ИИ-Маэстро',       'AI Maestro',      4,  1500, '👑', '#A855F7', 'from-purple-500/15 to-purple-500/5', 3.0,  '{"daily_generations": 50, "can_vote": true, "can_curate": true, "vote_highlight": true, "featured_profile": true}')
ON CONFLICT (key) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  name_en = EXCLUDED.name_en,
  min_xp = EXCLUDED.min_xp,
  icon = EXCLUDED.icon,
  color = EXCLUDED.color,
  gradient = EXCLUDED.gradient,
  vote_weight = EXCLUDED.vote_weight,
  perks = EXCLUDED.perks;

-- ─── 5. Seed achievements ───────────────────────────────

INSERT INTO public.achievements (key, name, name_ru, description, description_ru, icon, category, rarity, requirement_type, requirement_value, xp_reward, credit_reward, sort_order)
VALUES
  -- Forum
  ('first_post',         'First Post',         'Первый пост',          'Write your first forum post',         'Напишите первый пост на форуме',           '✍️', 'forum',   'common',    'posts_created',      1,   10, 0, 10),
  ('topic_starter',      'Topic Starter',      'Автор тем',            'Create 10 forum topics',              'Создайте 10 тем на форуме',                '📝', 'forum',   'common',    'topics_created',    10,   25, 5, 11),
  ('helpful_answer',     'Helpful Answer',     'Полезный ответ',       'Get 5 solutions marked',              'Получите 5 отметок «решение»',             '💡', 'forum',   'rare',      'solutions_count',    5,   50, 10, 12),
  ('forum_guru',         'Forum Guru',         'Гуру форума',          'Reach 100 posts',                     'Напишите 100 постов',                      '🧠', 'forum',   'epic',      'posts_created',    100,  100, 25, 13),
  ('knowledge_keeper',   'Knowledge Keeper',   'Хранитель знаний',     'Create 5 guides/tutorials',           'Создайте 5 гайдов/туториалов',             '📚', 'creator', 'epic',      'guides_published',   5,  150, 50, 14),

  -- Music
  ('first_track',        'First Track',        'Первый трек',          'Generate your first track',           'Сгенерируйте свой первый трек',            '🎵', 'music',   'common',    'tracks_published',   1,   10, 0, 20),
  ('prolific_creator',   'Prolific Creator',   'Плодовитый автор',     'Publish 25 tracks',                   'Опубликуйте 25 треков',                    '🎶', 'music',   'common',    'tracks_published',  25,   50, 10, 21),
  ('hit_maker',          'Hit Maker',          'Хитмейкер',            'Get 100 likes on tracks',             'Получите 100 лайков на треки',              '🔥', 'music',   'rare',      'tracks_liked_received', 100, 100, 25, 22),
  ('chart_topper',       'Chart Topper',       'Топ чартов',           'Get 500 likes on tracks',             'Получите 500 лайков на треки',              '🏆', 'music',   'epic',      'tracks_liked_received', 500, 200, 50, 23),
  ('sound_pioneer',      'Sound Pioneer',      'Пионер звука',         'Publish 100 tracks',                  'Опубликуйте 100 треков',                   '🚀', 'music',   'legendary', 'tracks_published', 100,  300, 100, 24),

  -- Social
  ('social_butterfly',   'Social Butterfly',   'Социальная бабочка',   'Get 10 followers',                    'Получите 10 подписчиков',                  '🦋', 'social',  'common',    'followers_count',   10,   20, 5, 30),
  ('influencer',         'Influencer',         'Инфлюенсер',           'Get 50 followers',                    'Получите 50 подписчиков',                  '⭐', 'social',  'rare',      'followers_count',   50,   75, 20, 31),
  ('community_pillar',   'Community Pillar',   'Опора сообщества',     'Get 200 followers',                   'Получите 200 подписчиков',                 '🏛️', 'social',  'epic',      'followers_count',  200,  150, 50, 32),
  ('collaborator',       'Collaborator',       'Коллаборант',          'Complete 5 collaborations',           'Завершите 5 коллабораций',                 '🤝', 'social',  'rare',      'collaborations_count', 5, 100, 30, 33),

  -- Contest
  ('arena_debut',        'Arena Debut',        'Дебют на арене',       'Enter your first contest',            'Примите участие в первом конкурсе',        '⚔️', 'contest', 'common',    'contests_entered',   1,   15, 0, 40),
  ('arena_champion',     'Arena Champion',     'Чемпион арены',        'Win 3 contests',                      'Победите в 3 конкурсах',                   '🥇', 'contest', 'epic',      'contests_won',       3,  200, 75, 41),
  ('streak_fire',        'Streak Fire',        'Серия огня',           '7-day contest streak',                'Серия участия 7 дней подряд',              '🔥', 'contest', 'rare',      'streak_days',        7,   75, 20, 42),

  -- General / special
  ('early_adopter',      'Early Adopter',      'Ранний пользователь',  'Joined during beta',                  'Зарегистрировались в бета-периоде',        '🌟', 'general', 'legendary', 'manual',             1,  100, 50, 50),
  ('daily_devotion',     'Daily Devotion',     'Ежедневная преданность','30-day activity streak',              'Серия активности 30 дней подряд',          '📅', 'general', 'epic',      'streak_days',       30,  200, 75, 51),
  ('legend',             'Legend',             'Легенда',              'Reach AI Maestro tier',               'Достигните звания ИИ-Маэстро',            '👑', 'general', 'legendary', 'tier_reached',       4,  500, 200, 52)
ON CONFLICT (key) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description_ru = EXCLUDED.description_ru,
  icon = EXCLUDED.icon,
  category = EXCLUDED.category,
  rarity = EXCLUDED.rarity,
  requirement_type = EXCLUDED.requirement_type,
  requirement_value = EXCLUDED.requirement_value,
  xp_reward = EXCLUDED.xp_reward,
  credit_reward = EXCLUDED.credit_reward;

-- ─── 6. XP Event config ────────────────────────────────

CREATE TABLE IF NOT EXISTS public.xp_event_config (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  event_type TEXT NOT NULL UNIQUE,
  xp_amount INTEGER NOT NULL DEFAULT 0,
  reputation_amount INTEGER NOT NULL DEFAULT 0,
  category TEXT NOT NULL DEFAULT 'general',
  cooldown_minutes INTEGER DEFAULT 0,
  daily_limit INTEGER DEFAULT 0,
  requires_quality_check BOOLEAN DEFAULT false,
  description TEXT,
  is_active BOOLEAN DEFAULT true
);

INSERT INTO public.xp_event_config (event_type, xp_amount, reputation_amount, category, cooldown_minutes, daily_limit, requires_quality_check, description)
VALUES
  -- Forum events
  ('forum_post_created',     3,  1, 'forum',    2,  30, false, 'Создание поста на форуме'),
  ('forum_topic_created',    8,  3, 'forum',    5,  10, false, 'Создание темы на форуме'),
  ('forum_post_liked',       2,  1, 'forum',    0,  50, false, 'Получение лайка на пост'),
  ('forum_solution_marked',  15, 5, 'forum',    0,   0, false, 'Пост отмечен как решение'),
  ('forum_guide_published',  25, 10,'creator',  0,   5, true,  'Публикация гайда/туториала'),

  -- Music events
  ('track_published',        5,  2, 'music',    0,  20, false, 'Публикация трека'),
  ('track_liked',            2,  1, 'music',    0, 100, false, 'Получение лайка на трек'),
  ('track_played_10',        1,  0, 'music',    0,  50, false, 'Прослушивание трека 10 раз'),
  ('track_shared',           3,  1, 'music',    0,  20, false, 'Поделились треком'),
  ('cover_uploaded',         5,  2, 'music',    0,  10, false, 'Загрузка обложки'),

  -- Social events
  ('follower_gained',        3,  1, 'social',   0,   0, false, 'Получение подписчика'),
  ('comment_posted',         1,  0, 'social',   1,  30, false, 'Написание комментария'),
  ('collab_completed',      20,  8, 'social',   0,   5, true,  'Завершение коллаборации'),

  -- Contest events
  ('contest_entered',       10,  3, 'contest',  0,   5, false, 'Участие в конкурсе'),
  ('contest_won',           50, 20, 'contest',  0,   0, false, 'Победа в конкурсе'),
  ('contest_top3',          25, 10, 'contest',  0,   0, false, 'Топ-3 в конкурсе'),
  ('contest_voted',          1,  0, 'contest',  1,  30, false, 'Голосование в конкурсе'),

  -- General
  ('daily_login',            2,  0, 'general',  0,   1, false, 'Ежедневный вход'),
  ('profile_completed',     10,  5, 'general',  0,   1, false, 'Заполнение профиля'),
  ('streak_milestone',      20,  5, 'general',  0,   0, false, 'Достижение стрика')
ON CONFLICT (event_type) DO UPDATE SET
  xp_amount = EXCLUDED.xp_amount,
  reputation_amount = EXCLUDED.reputation_amount,
  category = EXCLUDED.category,
  cooldown_minutes = EXCLUDED.cooldown_minutes,
  daily_limit = EXCLUDED.daily_limit;

-- ─── 7. RPC: award_xp — центральная функция начисления ──

CREATE OR REPLACE FUNCTION public.award_xp(
  p_user_id UUID,
  p_event_type TEXT,
  p_source_type TEXT DEFAULT NULL,
  p_source_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_config RECORD;
  v_stats RECORD;
  v_tier RECORD;
  v_new_tier RECORD;
  v_daily_count INTEGER;
  v_cooldown_ok BOOLEAN;
  v_xp INTEGER;
  v_rep INTEGER;
  v_new_xp INTEGER;
  v_new_rep INTEGER;
  v_tier_changed BOOLEAN := false;
  v_achievements_earned INTEGER := 0;
BEGIN
  -- Get event config
  SELECT * INTO v_config FROM public.xp_event_config
  WHERE event_type = p_event_type AND is_active = true;

  IF v_config IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_event');
  END IF;

  v_xp := v_config.xp_amount;
  v_rep := v_config.reputation_amount;

  -- Check daily limit
  IF v_config.daily_limit > 0 THEN
    SELECT COUNT(*) INTO v_daily_count
    FROM public.reputation_events
    WHERE user_id = p_user_id
      AND event_type = p_event_type
      AND created_at >= CURRENT_DATE;

    IF v_daily_count >= v_config.daily_limit THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_limit');
    END IF;
  END IF;

  -- Check cooldown
  IF v_config.cooldown_minutes > 0 THEN
    SELECT NOT EXISTS(
      SELECT 1 FROM public.reputation_events
      WHERE user_id = p_user_id
        AND event_type = p_event_type
        AND created_at > now() - (v_config.cooldown_minutes || ' minutes')::interval
    ) INTO v_cooldown_ok;

    IF NOT v_cooldown_ok THEN
      RETURN jsonb_build_object('ok', false, 'error', 'cooldown');
    END IF;
  END IF;

  -- Ensure user stats exist
  INSERT INTO public.forum_user_stats (user_id, xp_total, xp_daily_earned, xp_daily_date)
  VALUES (p_user_id, 0, 0, CURRENT_DATE)
  ON CONFLICT (user_id) DO NOTHING;

  -- Reset daily XP if new day
  UPDATE public.forum_user_stats
  SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
  WHERE user_id = p_user_id AND xp_daily_date < CURRENT_DATE;

  -- Apply XP and reputation
  UPDATE public.forum_user_stats SET
    xp_total = COALESCE(xp_total, 0) + v_xp,
    xp_forum = CASE WHEN v_config.category = 'forum' THEN COALESCE(xp_forum, 0) + v_xp ELSE COALESCE(xp_forum, 0) END,
    xp_music = CASE WHEN v_config.category IN ('music', 'creator') THEN COALESCE(xp_music, 0) + v_xp ELSE COALESCE(xp_music, 0) END,
    xp_social = CASE WHEN v_config.category = 'social' THEN COALESCE(xp_social, 0) + v_xp ELSE COALESCE(xp_social, 0) END,
    xp_daily_earned = COALESCE(xp_daily_earned, 0) + v_xp,
    reputation_score = COALESCE(reputation_score, 0) + v_rep,
    last_activity_date = CURRENT_DATE,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING * INTO v_stats;

  -- Log event
  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, source_type, source_id, metadata)
  VALUES (p_user_id, p_event_type, v_xp, v_rep, v_config.category, p_source_type, p_source_id, p_metadata);

  -- Check tier upgrade
  SELECT * INTO v_tier FROM public.reputation_tiers
  WHERE min_xp <= COALESCE(v_stats.xp_total, 0)
  ORDER BY level DESC LIMIT 1;

  IF v_tier IS NOT NULL AND v_tier.key != COALESCE(v_stats.tier, 'newcomer') THEN
    UPDATE public.forum_user_stats SET
      tier = v_tier.key,
      vote_weight = v_tier.vote_weight,
      trust_level = v_tier.level
    WHERE user_id = p_user_id;
    v_tier_changed := true;

    -- Notify on tier upgrade
    INSERT INTO public.notifications (user_id, type, title, message, data)
    VALUES (p_user_id, 'achievement', 'Новое звание!',
      'Поздравляем! Вы достигли звания «' || v_tier.name_ru || '»',
      jsonb_build_object('tier', v_tier.key, 'tier_name', v_tier.name_ru, 'icon', v_tier.icon));
  END IF;

  -- Update streak
  IF v_stats.last_activity_date IS NULL OR v_stats.last_activity_date < CURRENT_DATE THEN
    IF v_stats.last_activity_date = CURRENT_DATE - 1 THEN
      UPDATE public.forum_user_stats SET
        streak_days = COALESCE(streak_days, 0) + 1,
        best_streak = GREATEST(COALESCE(best_streak, 0), COALESCE(streak_days, 0) + 1)
      WHERE user_id = p_user_id;
    ELSIF v_stats.last_activity_date IS NULL OR v_stats.last_activity_date < CURRENT_DATE - 1 THEN
      UPDATE public.forum_user_stats SET streak_days = 1 WHERE user_id = p_user_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'xp_awarded', v_xp,
    'rep_awarded', v_rep,
    'total_xp', COALESCE(v_stats.xp_total, 0),
    'tier_changed', v_tier_changed,
    'new_tier', COALESCE(v_tier.key, 'newcomer')
  );
END;
$$;

-- ─── 8. RPC: check_user_achievements ────────────────────

CREATE OR REPLACE FUNCTION public.check_user_achievements(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_achievement RECORD;
  v_earned INTEGER := 0;
  v_current_value INTEGER;
  v_stats RECORD;
  v_profile RECORD;
BEGIN
  -- Get user stats
  SELECT * INTO v_stats FROM public.forum_user_stats WHERE user_id = p_user_id;
  IF v_stats IS NULL THEN RETURN 0; END IF;

  -- Get profile data
  SELECT
    (SELECT COUNT(*) FROM public.follows WHERE following_id = p_user_id) as followers_count,
    (SELECT COUNT(*) FROM public.contest_entries WHERE user_id = p_user_id) as contests_entered,
    (SELECT COUNT(*) FROM public.contest_winners WHERE user_id = p_user_id AND place = 1) as contests_won
  INTO v_profile;

  FOR v_achievement IN
    SELECT a.* FROM public.achievements a
    WHERE a.is_active = true
      AND a.requirement_type != 'manual'
      AND NOT EXISTS (
        SELECT 1 FROM public.user_achievements ua
        WHERE ua.user_id = p_user_id AND ua.achievement_id = a.id
      )
  LOOP
    v_current_value := CASE v_achievement.requirement_type
      WHEN 'posts_created' THEN COALESCE(v_stats.posts_created, 0)
      WHEN 'topics_created' THEN COALESCE(v_stats.topics_created, 0)
      WHEN 'solutions_count' THEN COALESCE(v_stats.solutions_count, 0)
      WHEN 'tracks_published' THEN COALESCE(v_stats.tracks_published, 0)
      WHEN 'tracks_liked_received' THEN COALESCE(v_stats.tracks_liked_received, 0)
      WHEN 'guides_published' THEN COALESCE(v_stats.guides_published, 0)
      WHEN 'followers_count' THEN COALESCE(v_profile.followers_count, 0)
      WHEN 'collaborations_count' THEN COALESCE(v_stats.collaborations_count, 0)
      WHEN 'contests_entered' THEN COALESCE(v_profile.contests_entered, 0)
      WHEN 'contests_won' THEN COALESCE(v_profile.contests_won, 0)
      WHEN 'streak_days' THEN COALESCE(v_stats.streak_days, 0)
      WHEN 'tier_reached' THEN (SELECT level FROM public.reputation_tiers WHERE key = v_stats.tier)
      ELSE 0
    END;

    IF v_current_value >= v_achievement.requirement_value THEN
      INSERT INTO public.user_achievements (user_id, achievement_id)
      VALUES (p_user_id, v_achievement.id)
      ON CONFLICT DO NOTHING;

      -- Award XP and credits for achievement
      IF v_achievement.xp_reward > 0 THEN
        UPDATE public.forum_user_stats SET
          xp_total = COALESCE(xp_total, 0) + v_achievement.xp_reward
        WHERE user_id = p_user_id;
      END IF;

      IF v_achievement.credit_reward > 0 THEN
        UPDATE public.profiles SET
          credits = COALESCE(credits, 0) + v_achievement.credit_reward
        WHERE id = p_user_id;
      END IF;

      -- Notify
      INSERT INTO public.notifications (user_id, type, title, message, data)
      VALUES (p_user_id, 'achievement', 'Достижение разблокировано!',
        v_achievement.icon || ' ' || v_achievement.name_ru,
        jsonb_build_object(
          'achievement_key', v_achievement.key,
          'achievement_name', v_achievement.name_ru,
          'icon', v_achievement.icon,
          'xp_reward', v_achievement.xp_reward,
          'credit_reward', v_achievement.credit_reward
        ));

      v_earned := v_earned + 1;
    END IF;
  END LOOP;

  RETURN v_earned;
END;
$$;

-- ─── 9. RPC: get_reputation_profile ─────────────────────

CREATE OR REPLACE FUNCTION public.get_reputation_profile(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_stats RECORD;
  v_tier RECORD;
  v_next_tier RECORD;
  v_rank INTEGER;
  v_achievements_count INTEGER;
  v_result JSONB;
BEGIN
  SELECT * INTO v_stats FROM public.forum_user_stats WHERE user_id = p_user_id;

  IF v_stats IS NULL THEN
    RETURN jsonb_build_object(
      'xp_total', 0, 'tier', 'newcomer', 'tier_name', 'Новичок',
      'tier_icon', '🎵', 'tier_color', '#6B7280', 'tier_level', 0,
      'xp_forum', 0, 'xp_music', 0, 'xp_social', 0,
      'reputation_score', 0, 'vote_weight', 1.0,
      'streak_days', 0, 'best_streak', 0,
      'global_rank', 0, 'achievements_count', 0,
      'next_tier_name', 'Битмейкер', 'next_tier_xp', 50, 'progress', 0
    );
  END IF;

  -- Current tier
  SELECT * INTO v_tier FROM public.reputation_tiers
  WHERE min_xp <= COALESCE(v_stats.xp_total, 0)
  ORDER BY level DESC LIMIT 1;

  -- Next tier
  SELECT * INTO v_next_tier FROM public.reputation_tiers
  WHERE level = COALESCE(v_tier.level, 0) + 1;

  -- Global rank
  SELECT COUNT(*) + 1 INTO v_rank FROM public.forum_user_stats
  WHERE xp_total > COALESCE(v_stats.xp_total, 0);

  -- Achievements count
  SELECT COUNT(*) INTO v_achievements_count FROM public.user_achievements
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'xp_total', COALESCE(v_stats.xp_total, 0),
    'xp_forum', COALESCE(v_stats.xp_forum, 0),
    'xp_music', COALESCE(v_stats.xp_music, 0),
    'xp_social', COALESCE(v_stats.xp_social, 0),
    'xp_daily_earned', COALESCE(v_stats.xp_daily_earned, 0),
    'reputation_score', COALESCE(v_stats.reputation_score, 0),
    'tier', COALESCE(v_tier.key, 'newcomer'),
    'tier_name', COALESCE(v_tier.name_ru, 'Новичок'),
    'tier_icon', COALESCE(v_tier.icon, '🎵'),
    'tier_color', COALESCE(v_tier.color, '#6B7280'),
    'tier_gradient', COALESCE(v_tier.gradient, 'from-gray-500/15 to-gray-500/5'),
    'tier_level', COALESCE(v_tier.level, 0),
    'vote_weight', COALESCE(v_tier.vote_weight, 1.0),
    'perks', COALESCE(v_tier.perks, '{}'),
    'streak_days', COALESCE(v_stats.streak_days, 0),
    'best_streak', COALESCE(v_stats.best_streak, 0),
    'tracks_published', COALESCE(v_stats.tracks_published, 0),
    'tracks_liked_received', COALESCE(v_stats.tracks_liked_received, 0),
    'guides_published', COALESCE(v_stats.guides_published, 0),
    'global_rank', v_rank,
    'achievements_count', v_achievements_count,
    'next_tier_name', v_next_tier.name_ru,
    'next_tier_xp', v_next_tier.min_xp,
    'progress', CASE
      WHEN v_next_tier IS NULL THEN 100
      WHEN v_tier IS NULL THEN 0
      ELSE LEAST(100, ((COALESCE(v_stats.xp_total, 0) - v_tier.min_xp)::numeric / GREATEST(1, v_next_tier.min_xp - v_tier.min_xp) * 100)::integer)
    END
  );
END;
$$;

-- ─── 10. RPC: get_reputation_leaderboard ────────────────

CREATE OR REPLACE FUNCTION public.get_reputation_leaderboard(
  p_type TEXT DEFAULT 'xp',
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  pos BIGINT,
  user_id UUID,
  username TEXT,
  avatar_url TEXT,
  xp_total INTEGER,
  reputation_score INTEGER,
  tier TEXT,
  tier_name TEXT,
  tier_icon TEXT,
  tier_color TEXT,
  streak_days INTEGER,
  achievements_count BIGINT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY
        CASE p_type
          WHEN 'xp' THEN COALESCE(s.xp_total, 0)
          WHEN 'reputation' THEN COALESCE(s.reputation_score, 0)
          WHEN 'streak' THEN COALESCE(s.streak_days, 0)
          ELSE COALESCE(s.xp_total, 0)
        END DESC
    ) as pos,
    s.user_id,
    p.username::TEXT,
    p.avatar_url::TEXT,
    COALESCE(s.xp_total, 0)::INTEGER as xp_total,
    COALESCE(s.reputation_score, 0)::INTEGER as reputation_score,
    COALESCE(s.tier, 'newcomer')::TEXT as tier,
    COALESCE(t.name_ru, 'Новичок')::TEXT as tier_name,
    COALESCE(t.icon, '🎵')::TEXT as tier_icon,
    COALESCE(t.color, '#6B7280')::TEXT as tier_color,
    COALESCE(s.streak_days, 0)::INTEGER as streak_days,
    (SELECT COUNT(*) FROM public.user_achievements ua WHERE ua.user_id = s.user_id) as achievements_count
  FROM public.forum_user_stats s
  JOIN public.profiles p ON p.id = s.user_id
  LEFT JOIN public.reputation_tiers t ON t.key = s.tier
  WHERE COALESCE(s.xp_total, 0) > 0
  ORDER BY
    CASE p_type
      WHEN 'xp' THEN COALESCE(s.xp_total, 0)
      WHEN 'reputation' THEN COALESCE(s.reputation_score, 0)
      WHEN 'streak' THEN COALESCE(s.streak_days, 0)
      ELSE COALESCE(s.xp_total, 0)
    END DESC
  LIMIT p_limit;
END;
$$;

-- ─── 11. Weighted vote function ─────────────────────────

CREATE OR REPLACE FUNCTION public.get_user_vote_weight(p_user_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_weight NUMERIC;
BEGIN
  SELECT COALESCE(vote_weight, 1.0) INTO v_weight
  FROM public.forum_user_stats WHERE user_id = p_user_id;
  RETURN COALESCE(v_weight, 1.0);
END;
$$;

-- ─── 12. RLS Policies ──────────────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'achievements' AND policyname = 'achievements_public_read') THEN
    CREATE POLICY achievements_public_read ON public.achievements FOR SELECT USING (true);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'user_achievements' AND policyname = 'user_achievements_public_read') THEN
    CREATE POLICY user_achievements_public_read ON public.user_achievements FOR SELECT USING (true);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'reputation_tiers' AND policyname = 'reputation_tiers_public_read') THEN
    CREATE POLICY reputation_tiers_public_read ON public.reputation_tiers FOR SELECT USING (true);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'reputation_events' AND policyname = 'reputation_events_own_read') THEN
    CREATE POLICY reputation_events_own_read ON public.reputation_events FOR SELECT USING (auth.uid() = user_id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'xp_event_config' AND policyname = 'xp_event_config_public_read') THEN
    CREATE POLICY xp_event_config_public_read ON public.xp_event_config FOR SELECT USING (true);
  END IF;
END $$;

-- Enable RLS
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.xp_event_config ENABLE ROW LEVEL SECURITY;
