-- ═══════════════════════════════════════════════════════════════
-- 031-qa-rewards-fix.sql
-- Исправление: XP не начислялись при подтверждении баг-репорта.
-- Причина: award_xp вызывался с неверными аргументами, qa_report_resolved
-- отсутствовал в xp_event_config. Начисляем XP напрямую.
-- ═══════════════════════════════════════════════════════════════

-- 1. Добавить qa_report_resolved в xp_event_config (для будущего использования)
INSERT INTO public.xp_event_config (event_type, xp_amount, reputation_amount, category, cooldown_minutes, daily_limit, requires_quality_check, description)
VALUES ('qa_report_resolved', 15, 5, 'general', 0, 20, false, 'Подтверждённый баг-репорт')
ON CONFLICT (event_type) DO UPDATE SET
  xp_amount = EXCLUDED.xp_amount,
  reputation_amount = EXCLUDED.reputation_amount,
  category = EXCLUDED.category,
  cooldown_minutes = EXCLUDED.cooldown_minutes,
  daily_limit = EXCLUDED.daily_limit,
  description = EXCLUDED.description;


-- 2. Заменить resolve_qa_ticket: начисление XP и рубли при любом статусе, если указаны награды
DROP FUNCTION IF EXISTS public.resolve_qa_ticket(UUID, TEXT, TEXT, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION public.resolve_qa_ticket(
  p_ticket_id UUID,
  p_status TEXT,
  p_notes TEXT DEFAULT NULL,
  p_reward_xp INTEGER DEFAULT 0,
  p_reward_credits INTEGER DEFAULT 0
)
RETURNS JSONB AS $$
DECLARE
  v_admin_id UUID;
  v_reporter_id UUID;
  v_old_status TEXT;
  v_bounty_id UUID;
  v_bounty RECORD;
  v_final_xp INTEGER;
  v_final_credits INTEGER;
  v_rep INTEGER;
  v_tier RECORD;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT reporter_id, status, bounty_id INTO v_reporter_id, v_old_status, v_bounty_id
    FROM public.qa_tickets WHERE id = p_ticket_id;
  IF v_reporter_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ticket not found');
  END IF;

  -- Итоговые награды: из параметров или из баунти
  v_final_xp := p_reward_xp;
  v_final_credits := p_reward_credits;

  IF v_bounty_id IS NOT NULL AND (v_final_xp = 0 AND v_final_credits = 0) THEN
    SELECT reward_xp, reward_credits, is_active, claimed_count, max_claims
    INTO v_bounty
    FROM public.qa_bounties WHERE id = v_bounty_id;

    IF v_bounty IS NOT NULL AND v_bounty.is_active AND v_bounty.claimed_count < v_bounty.max_claims THEN
      v_final_xp := v_bounty.reward_xp;
      v_final_credits := v_bounty.reward_credits;
    END IF;
  END IF;

  -- Обновить тикет
  UPDATE public.qa_tickets SET
    status = p_status,
    resolution_notes = COALESCE(p_notes, resolution_notes),
    resolved_by = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN v_admin_id ELSE resolved_by END,
    resolved_at = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN now() ELSE resolved_at END,
    reward_xp = CASE WHEN v_final_xp > 0 THEN v_final_xp ELSE reward_xp END,
    reward_credits = CASE WHEN v_final_credits > 0 THEN v_final_credits ELSE reward_credits END
  WHERE id = p_ticket_id;

  -- Наградить репортёра при любом статусе (confirmed, fixed и т.д.), если указаны награды
  IF (v_final_xp > 0 OR v_final_credits > 0) AND NOT public.is_user_blocked(v_reporter_id) THEN
    -- QA tester stats
    INSERT INTO public.qa_tester_stats (user_id, xp_earned, credits_earned)
      VALUES (v_reporter_id, v_final_xp, v_final_credits)
      ON CONFLICT (user_id) DO UPDATE SET
        xp_earned = qa_tester_stats.xp_earned + v_final_xp,
        credits_earned = qa_tester_stats.credits_earned + v_final_credits;

    -- XP: прямое начисление в forum_user_stats (обход award_xp с неверной сигнатурой)
    IF v_final_xp > 0 THEN
      v_rep := LEAST(v_final_xp / 2, 10);

      INSERT INTO public.forum_user_stats (user_id, xp_total, xp_daily_earned, xp_daily_date, reputation_score, last_activity_date, updated_at)
      VALUES (v_reporter_id, v_final_xp, v_final_xp, CURRENT_DATE, v_rep, CURRENT_DATE, now())
      ON CONFLICT (user_id) DO UPDATE SET
        xp_total = COALESCE(forum_user_stats.xp_total, 0) + v_final_xp,
        xp_daily_earned = COALESCE(forum_user_stats.xp_daily_earned, 0) + v_final_xp,
        xp_daily_date = CURRENT_DATE,
        reputation_score = COALESCE(forum_user_stats.reputation_score, 0) + v_rep,
        last_activity_date = CURRENT_DATE,
        updated_at = now();

      -- Пересчёт тира
      SELECT * INTO v_tier FROM public.reputation_tiers
      WHERE min_xp <= (SELECT COALESCE(xp_total, 0) FROM public.forum_user_stats WHERE user_id = v_reporter_id)
      ORDER BY level DESC LIMIT 1;
      IF v_tier IS NOT NULL THEN
        UPDATE public.forum_user_stats SET
          tier = v_tier.key,
          vote_weight = v_tier.vote_weight,
          trust_level = v_tier.level
        WHERE user_id = v_reporter_id;
      END IF;

      -- Лог события
      INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, source_type, source_id, metadata)
      VALUES (v_reporter_id, 'qa_report_resolved', v_final_xp, v_rep, 'general', 'qa_ticket', p_ticket_id,
        jsonb_build_object('xp_custom', v_final_xp, 'bounty_id', v_bounty_id));
    END IF;

    -- Рубли: на баланс профиля
    IF v_final_credits > 0 THEN
      UPDATE public.profiles SET balance = balance + v_final_credits
      WHERE user_id = v_reporter_id;

      INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id)
      VALUES (v_reporter_id, v_final_credits, 'qa_reward', 'Награда за найденную ошибку #' || LEFT(p_ticket_id::text, 8), 'qa_ticket', p_ticket_id);
    END IF;

    -- Баунти: claimed_count
    IF v_bounty_id IS NOT NULL AND p_status = 'fixed' THEN
      UPDATE public.qa_bounties SET claimed_count = claimed_count + 1 WHERE id = v_bounty_id;
      UPDATE public.qa_bounties SET is_active = false WHERE id = v_bounty_id AND claimed_count >= max_claims;
    END IF;
  END IF;

  -- Статистика по статусу
  IF p_status = 'fixed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_confirmed)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET reports_confirmed = qa_tester_stats.reports_confirmed + 1;
  ELSIF p_status IN ('wont_fix', 'closed') THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_rejected)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET reports_rejected = qa_tester_stats.reports_rejected + 1;
  END IF;

  PERFORM public.qa_update_tester_tier(v_reporter_id);

  -- Системный комментарий
  INSERT INTO public.qa_comments (ticket_id, user_id, message, is_staff, is_system)
  VALUES (p_ticket_id, v_admin_id,
    CASE p_status
      WHEN 'fixed' THEN 'Баг исправлен. ' || COALESCE(p_notes, '')
      WHEN 'wont_fix' THEN 'Не будет исправлено. ' || COALESCE(p_notes, '')
      WHEN 'duplicate' THEN 'Дубликат. ' || COALESCE(p_notes, '')
      WHEN 'closed' THEN 'Закрыт. ' || COALESCE(p_notes, '')
      ELSE 'Статус изменён на ' || p_status || '. ' || COALESCE(p_notes, '')
    END, true, true);

  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
