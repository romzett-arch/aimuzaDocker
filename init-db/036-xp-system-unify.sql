-- ============================================================
-- 036: Унификация XP-системы
-- 
-- Исправления:
-- 1. fn_add_xp: убрана зависимость от forum_automod_settings (key/value)
-- 2. fn_add_xp: tier пересчитывается по reputation_tiers (единый источник)
-- 3. fn_add_xp: логирование в reputation_events
-- 4. check_user_achievements: логирование + fix profiles WHERE
-- 5. check_user_achievements: добавлены contests_entered/won колонки
-- 6. check_user_achievements: добавлены posts_created/topics_created/solutions_count
-- ============================================================

-- ─── 0. Недостающие колонки ───────────────────────────────

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS contests_entered INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS contests_won INTEGER NOT NULL DEFAULT 0;

-- ─── 1. fn_add_xp — unified ─────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_add_xp(
  p_user_id UUID, p_amount NUMERIC, p_category TEXT DEFAULT 'forum'
) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_daily_cap INTEGER := 100;
  v_current_daily INTEGER;
  v_actual_amount INTEGER;
  v_new_total INTEGER;
  v_tier RECORD;
  v_event_type TEXT;
BEGIN
  INSERT INTO forum_user_stats (user_id)
    VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;

  UPDATE forum_user_stats
    SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
    WHERE user_id = p_user_id
      AND (xp_daily_date IS NULL OR xp_daily_date < CURRENT_DATE);

  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily
    FROM forum_user_stats WHERE user_id = p_user_id;

  IF p_amount > 0 THEN
    v_actual_amount := LEAST(p_amount::integer, v_daily_cap - v_current_daily);
    IF v_actual_amount <= 0 THEN RETURN 0; END IF;
  ELSE
    v_actual_amount := p_amount::integer;
  END IF;

  UPDATE forum_user_stats SET
    xp_total = GREATEST(0, xp_total + v_actual_amount),
    xp_daily_earned = CASE WHEN v_actual_amount > 0
      THEN xp_daily_earned + v_actual_amount ELSE xp_daily_earned END,
    xp_forum = CASE WHEN p_category = 'forum'
      THEN GREATEST(0, xp_forum + v_actual_amount) ELSE xp_forum END,
    xp_music = CASE WHEN p_category = 'music'
      THEN GREATEST(0, xp_music + v_actual_amount) ELSE xp_music END,
    xp_social = CASE WHEN p_category = 'social'
      THEN GREATEST(0, xp_social + v_actual_amount) ELSE xp_social END,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_total;

  -- Пересчёт tier по reputation_tiers (единый источник)
  SELECT * INTO v_tier FROM public.reputation_tiers
    WHERE min_xp <= COALESCE(v_new_total, 0)
    ORDER BY level DESC LIMIT 1;

  IF v_tier IS NOT NULL THEN
    UPDATE forum_user_stats SET
      tier = v_tier.key,
      vote_weight = v_tier.vote_weight,
      trust_level = v_tier.level
    WHERE user_id = p_user_id;
  END IF;

  -- event_type для reputation_events
  v_event_type := CASE p_category
    WHEN 'forum' THEN 'forum_xp'
    WHEN 'music' THEN 'music_xp'
    WHEN 'social' THEN 'social_xp'
    ELSE 'general_xp'
  END;

  -- Логирование
  IF v_actual_amount <> 0 THEN
    INSERT INTO public.reputation_events
      (user_id, event_type, xp_delta, reputation_delta, category, source_type, metadata)
    VALUES
      (p_user_id, v_event_type, v_actual_amount, 0, p_category, 'trigger',
       jsonb_build_object('via', 'fn_add_xp'));
  END IF;

  RETURN COALESCE(v_actual_amount, 0);
END; $$;


-- ─── 2. check_user_achievements — полный список requirement_type ──

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
  SELECT * INTO v_stats FROM public.forum_user_stats WHERE user_id = p_user_id;
  SELECT * INTO v_profile FROM public.profiles WHERE user_id = p_user_id;

  IF v_stats IS NULL THEN RETURN 0; END IF;

  FOR v_achievement IN
    SELECT a.* FROM public.achievements a
    WHERE a.is_active = true
      AND NOT EXISTS (
        SELECT 1 FROM public.user_achievements ua
        WHERE ua.user_id = p_user_id AND ua.achievement_id = a.id
      )
    ORDER BY a.sort_order
  LOOP
    v_current_value := CASE v_achievement.requirement_type
      WHEN 'xp_total' THEN COALESCE(v_stats.xp_total, 0)
      WHEN 'xp_forum' THEN COALESCE(v_stats.xp_forum, 0)
      WHEN 'xp_music' THEN COALESCE(v_stats.xp_music, 0)
      WHEN 'xp_social' THEN COALESCE(v_stats.xp_social, 0)
      WHEN 'reputation_score' THEN COALESCE(v_stats.reputation_score, 0)
      WHEN 'tracks_published' THEN COALESCE(v_stats.tracks_published, 0)
      WHEN 'tracks_liked_received' THEN COALESCE(v_stats.tracks_liked_received, 0)
      WHEN 'guides_published' THEN COALESCE(v_stats.guides_published, 0)
      WHEN 'followers_count' THEN COALESCE(v_profile.followers_count, 0)
      WHEN 'collaborations_count' THEN COALESCE(v_stats.collaborations_count, 0)
      WHEN 'contests_entered' THEN COALESCE(v_profile.contests_entered, 0)
      WHEN 'contests_won' THEN COALESCE(v_profile.contests_won, 0)
      WHEN 'streak_days' THEN COALESCE(v_stats.streak_days, 0)
      WHEN 'tier_reached' THEN COALESCE((SELECT level FROM public.reputation_tiers WHERE key = v_stats.tier), 0)
      WHEN 'posts_created' THEN COALESCE(v_stats.posts_created, 0)
      WHEN 'topics_created' THEN COALESCE(v_stats.topics_created, 0)
      WHEN 'solutions_count' THEN COALESCE(v_stats.solutions_count, 0)
      WHEN 'manual' THEN 0
      ELSE 0
    END;

    IF v_current_value >= v_achievement.requirement_value THEN
      INSERT INTO public.user_achievements (user_id, achievement_id)
      VALUES (p_user_id, v_achievement.id)
      ON CONFLICT DO NOTHING;

      IF v_achievement.xp_reward > 0 THEN
        UPDATE public.forum_user_stats SET
          xp_total = COALESCE(xp_total, 0) + v_achievement.xp_reward
        WHERE user_id = p_user_id;

        INSERT INTO public.reputation_events
          (user_id, event_type, xp_delta, reputation_delta, category, source_type, source_id, metadata)
        VALUES
          (p_user_id, 'achievement_unlocked', v_achievement.xp_reward, 0, 'general',
           'achievement', v_achievement.id,
           jsonb_build_object('achievement_key', v_achievement.key, 'achievement_name', v_achievement.name_ru));
      END IF;

      IF v_achievement.credit_reward > 0 THEN
        UPDATE public.profiles SET
          credits = COALESCE(credits, 0) + v_achievement.credit_reward
        WHERE user_id = p_user_id;
      END IF;

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
