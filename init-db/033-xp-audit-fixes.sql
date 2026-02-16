-- ═══════════════════════════════════════════════════════════════
-- 033-xp-audit-fixes.sql
-- Исправления по аудиту XP: add_user_credits, check_user_achievements
-- ═══════════════════════════════════════════════════════════════

-- 1. add_user_credits — используется в useAdminWorkflows.QABountyCloseWorkflow
-- Без неё начисление рублей за баунти падает
CREATE OR REPLACE FUNCTION public.add_user_credits(
  p_user_id UUID,
  p_amount INTEGER,
  p_reason TEXT DEFAULT 'Начисление'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_new_balance INTEGER;
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_must_be_positive');
  END IF;

  UPDATE public.profiles
  SET balance = balance + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type)
  VALUES (p_user_id, p_amount, 'credit_reward', p_reason, 'system');

  RETURN jsonb_build_object('ok', true, 'new_balance', v_new_balance);
END;
$$;


-- 2. Исправить check_user_achievements: profiles.id → profiles.user_id
-- Было: WHERE id = p_user_id (id — это PK, не user_id)
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
  IF v_stats IS NULL THEN RETURN 0; END IF;

  SELECT
    (SELECT COUNT(*) FROM public.user_follows WHERE following_id = p_user_id) as followers_count,
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

      IF v_achievement.xp_reward > 0 THEN
        UPDATE public.forum_user_stats SET
          xp_total = COALESCE(xp_total, 0) + v_achievement.xp_reward
        WHERE user_id = p_user_id;
      END IF;

      -- ИСПРАВЛЕНО: user_id вместо id (profiles.user_id = auth user)
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
