-- ═══════════════════════════════════════════════════════════════
-- Consolidate XP Caps: single source of truth
-- Moves global XP daily cap from forum_automod_settings to economy_config
-- Updates award_xp to enforce global daily/weekly/monthly caps
-- ═══════════════════════════════════════════════════════════════

-- Note: xp_daily_cap was originally hardcoded in old award_xp function.
-- Now it reads from economy_config.inflation_control (single source of truth).

-- Patch award_xp: add global cap enforcement from economy_config
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
  -- Global caps from economy_config
  v_inflation JSONB;
  v_global_daily_cap INTEGER;
  v_global_weekly_soft INTEGER;
  v_weekly_multiplier NUMERIC;
  v_global_monthly_hard INTEGER;
  v_current_daily_xp INTEGER;
  v_current_weekly_xp INTEGER;
  v_current_monthly_xp INTEGER;
BEGIN
  -- Get event config
  SELECT * INTO v_config FROM public.xp_event_config
  WHERE event_type = p_event_type AND is_active = true;

  IF v_config IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_event');
  END IF;

  v_xp := v_config.xp_amount;
  v_rep := v_config.reputation_amount;

  -- Check per-event daily limit
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

  -- ─── Global XP caps from economy_config ───
  SELECT value INTO v_inflation FROM public.economy_config WHERE key = 'inflation_control';
  v_global_daily_cap   := COALESCE((v_inflation->>'xp_daily_cap')::integer, 150);
  v_global_weekly_soft := COALESCE((v_inflation->>'xp_weekly_soft_cap')::integer, 800);
  v_weekly_multiplier  := COALESCE((v_inflation->>'xp_weekly_multiplier_after_cap')::numeric, 0.5);
  v_global_monthly_hard := COALESCE((v_inflation->>'xp_monthly_hard_cap')::integer, 2500);

  -- Ensure user stats exist
  INSERT INTO public.forum_user_stats (user_id, xp_total, xp_daily_earned, xp_daily_date)
  VALUES (p_user_id, 0, 0, CURRENT_DATE)
  ON CONFLICT (user_id) DO NOTHING;

  -- Reset daily XP if new day
  UPDATE public.forum_user_stats
  SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
  WHERE user_id = p_user_id AND xp_daily_date < CURRENT_DATE;

  -- Get current daily earned
  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily_xp
  FROM public.forum_user_stats WHERE user_id = p_user_id;

  -- Enforce global daily cap
  IF v_current_daily_xp >= v_global_daily_cap THEN
    RETURN jsonb_build_object('ok', false, 'error', 'global_daily_cap');
  END IF;
  -- Clamp XP to not exceed daily cap
  v_xp := LEAST(v_xp, v_global_daily_cap - v_current_daily_xp);

  -- Check weekly earned (soft cap: reduce XP)
  SELECT COALESCE(SUM(xp_delta), 0) INTO v_current_weekly_xp
  FROM public.reputation_events
  WHERE user_id = p_user_id
    AND xp_delta > 0
    AND created_at >= date_trunc('week', CURRENT_DATE);

  IF v_current_weekly_xp >= v_global_weekly_soft THEN
    v_xp := GREATEST(1, (v_xp * v_weekly_multiplier)::integer);
  END IF;

  -- Check monthly hard cap
  SELECT COALESCE(SUM(xp_delta), 0) INTO v_current_monthly_xp
  FROM public.reputation_events
  WHERE user_id = p_user_id
    AND xp_delta > 0
    AND created_at >= date_trunc('month', CURRENT_DATE);

  IF v_current_monthly_xp >= v_global_monthly_hard THEN
    RETURN jsonb_build_object('ok', false, 'error', 'monthly_hard_cap');
  END IF;
  v_xp := LEAST(v_xp, v_global_monthly_hard - v_current_monthly_xp);

  IF v_xp <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cap_reached');
  END IF;

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
    UPDATE public.forum_user_stats SET
      streak_days = CASE
        WHEN last_activity_date = CURRENT_DATE - 1 THEN COALESCE(streak_days, 0) + 1
        ELSE 1
      END,
      best_streak = GREATEST(
        COALESCE(best_streak, 0),
        CASE WHEN last_activity_date = CURRENT_DATE - 1 THEN COALESCE(streak_days, 0) + 1 ELSE 1 END
      )
    WHERE user_id = p_user_id;
  END IF;

  -- Check achievements
  BEGIN
    SELECT public.check_user_achievements(p_user_id) INTO v_achievements_earned;
  EXCEPTION WHEN OTHERS THEN
    v_achievements_earned := 0;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'xp_awarded', v_xp,
    'reputation_awarded', v_rep,
    'tier_changed', v_tier_changed,
    'new_tier', CASE WHEN v_tier_changed THEN v_tier.key ELSE NULL END,
    'achievements_earned', v_achievements_earned,
    'daily_remaining', v_global_daily_cap - v_current_daily_xp - v_xp
  );
END;
$$;
