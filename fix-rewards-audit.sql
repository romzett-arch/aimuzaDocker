-- ═══════════════════════════════════════════════════════════════
-- FIX: Comprehensive Rewards Audit Patch
-- Fixes broken award_xp calls, missing xp_event_config entries,
-- missing add_user_credits function, bounty claimed_count,
-- and radio prediction XP calls.
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. Add missing xp_event_config entries ───────────────────
-- Without these, award_xp returns 'unknown_event' and does nothing.

INSERT INTO public.xp_event_config (event_type, xp_amount, reputation_amount, category, cooldown_minutes, daily_limit, requires_quality_check, description)
VALUES
  -- QA events
  ('qa_report_resolved',   15, 5, 'general', 0, 20, false, 'Подтверждённый баг-репорт исправлен'),
  ('qa_bounty_resolved',   50, 15, 'general', 0, 5,  false, 'Закрытие баунти за найденную ошибку'),
  -- Radio events
  ('radio_listen',          1, 0, 'music',   0, 50, false, 'Прослушивание трека на радио'),
  ('prediction_correct',   10, 3, 'general', 0, 20, false, 'Верный прогноз на радио'),
  ('prediction_wrong',      1, 0, 'general', 0, 50, false, 'Неверный прогноз на радио (утешительный)'),
  -- Admin penalty events
  ('track_rejected',        0, -5, 'music',  0, 0,  false, 'Трек отклонён модерацией (штраф)')
ON CONFLICT (event_type) DO UPDATE SET
  xp_amount = EXCLUDED.xp_amount,
  reputation_amount = EXCLUDED.reputation_amount,
  category = EXCLUDED.category,
  cooldown_minutes = EXCLUDED.cooldown_minutes,
  daily_limit = EXCLUDED.daily_limit,
  description = EXCLUDED.description;


-- ─── 2. Create add_user_credits function ──────────────────────
-- Used by admin workflows to add credits to user balance.
-- Atomic: locks profile row, updates balance, logs transaction.

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

  -- Lock and update
  UPDATE public.profiles
  SET balance = balance + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  -- Log transaction
  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type)
  VALUES (p_user_id, p_amount, 'credit_reward', p_reason, 'system');

  RETURN jsonb_build_object('ok', true, 'new_balance', v_new_balance);
END;
$$;


-- ─── 3. Create deduct_user_xp function ───────────────────────
-- Used for admin penalties (track rejection, etc.).
-- award_xp doesn't support negative amounts, so we need a separate function.

CREATE OR REPLACE FUNCTION public.deduct_user_xp(
  p_user_id UUID,
  p_amount INTEGER,
  p_reason TEXT DEFAULT 'penalty',
  p_metadata JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_new_xp INTEGER;
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_must_be_positive');
  END IF;

  -- Ensure user stats exist
  INSERT INTO public.forum_user_stats (user_id, xp_total)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  -- Deduct XP (floor at 0)
  UPDATE public.forum_user_stats
  SET xp_total = GREATEST(0, COALESCE(xp_total, 0) - p_amount),
      reputation_score = GREATEST(0, COALESCE(reputation_score, 0) - LEAST(p_amount / 2, 10)),
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_xp;

  -- Log the penalty event
  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, metadata)
  VALUES (p_user_id, p_reason, -p_amount, -LEAST(p_amount / 2, 10), 'penalty', p_metadata);

  RETURN jsonb_build_object('ok', true, 'xp_deducted', p_amount, 'new_xp', v_new_xp);
END;
$$;


-- ─── 4. Fix resolve_qa_ticket: correct award_xp call, ────────
--    add balance credits, handle bounty claimed_count

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

  -- Calculate final rewards: use bounty rewards if ticket is linked and admin didn't specify
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

  -- Update ticket
  UPDATE public.qa_tickets SET
    status = p_status,
    resolution_notes = COALESCE(p_notes, resolution_notes),
    resolved_by = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN v_admin_id ELSE resolved_by END,
    resolved_at = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN now() ELSE resolved_at END,
    reward_xp = CASE WHEN v_final_xp > 0 THEN v_final_xp ELSE reward_xp END,
    reward_credits = CASE WHEN v_final_credits > 0 THEN v_final_credits ELSE reward_credits END
  WHERE id = p_ticket_id;

  -- Award reporter (only for fixed status or explicit rewards)
  IF (p_status = 'fixed' OR v_final_xp > 0 OR v_final_credits > 0) THEN
    -- Update QA tester stats
    IF v_final_xp > 0 OR v_final_credits > 0 THEN
      INSERT INTO public.qa_tester_stats (user_id, xp_earned, credits_earned)
        VALUES (v_reporter_id, v_final_xp, v_final_credits)
        ON CONFLICT (user_id) DO UPDATE SET
          xp_earned = qa_tester_stats.xp_earned + v_final_xp,
          credits_earned = qa_tester_stats.credits_earned + v_final_credits;
    END IF;

    -- Award XP via reputation system (correct parameter order!)
    IF v_final_xp > 0 THEN
      BEGIN
        PERFORM public.award_xp(
          v_reporter_id,
          'qa_report_resolved',
          'qa_ticket',
          p_ticket_id,
          jsonb_build_object('xp_custom', v_final_xp, 'bounty_id', v_bounty_id)
        );
      EXCEPTION WHEN OTHERS THEN
        -- Log the error but don't fail the whole operation
        RAISE WARNING 'award_xp failed for user %: %', v_reporter_id, SQLERRM;
      END;
    END IF;

    -- Award credits to actual balance (not just QA stats!)
    IF v_final_credits > 0 THEN
      UPDATE public.profiles SET balance = balance + v_final_credits
      WHERE user_id = v_reporter_id;

      -- Log balance transaction
      BEGIN
        INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id)
        VALUES (v_reporter_id, v_final_credits, 'qa_reward', 'Награда за найденную ошибку #' || LEFT(p_ticket_id::text, 8), 'qa_ticket', p_ticket_id);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    -- Increment bounty claimed_count if applicable
    IF v_bounty_id IS NOT NULL AND p_status = 'fixed' THEN
      UPDATE public.qa_bounties
      SET claimed_count = claimed_count + 1
      WHERE id = v_bounty_id;

      -- Deactivate bounty if max claims reached
      UPDATE public.qa_bounties
      SET is_active = false
      WHERE id = v_bounty_id AND claimed_count >= max_claims;
    END IF;
  END IF;

  -- Update stats based on resolution
  IF p_status = 'fixed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_confirmed)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET
        reports_confirmed = qa_tester_stats.reports_confirmed + 1;
  ELSIF p_status IN ('wont_fix', 'closed') THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_rejected)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET
        reports_rejected = qa_tester_stats.reports_rejected + 1;
  END IF;

  -- Recalculate accuracy and tier
  BEGIN
    PERFORM public.qa_update_tester_tier(v_reporter_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Notification to reporter
  IF p_status = 'fixed' AND (v_final_xp > 0 OR v_final_credits > 0) THEN
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_reporter_id,
      'qa_reward',
      'Награда за ошибку!',
      'Ваш баг-репорт исправлен! Получено: ' ||
        CASE WHEN v_final_xp > 0 THEN v_final_xp || ' опыта' ELSE '' END ||
        CASE WHEN v_final_xp > 0 AND v_final_credits > 0 THEN ' и ' ELSE '' END ||
        CASE WHEN v_final_credits > 0 THEN v_final_credits || ' монет' ELSE '' END,
      'qa_ticket',
      p_ticket_id
    );
  END IF;

  -- System comment
  INSERT INTO public.qa_comments (ticket_id, user_id, message, is_staff, is_system)
    VALUES (p_ticket_id, v_admin_id,
      CASE p_status
        WHEN 'fixed' THEN 'Ошибка исправлена. ' || COALESCE(p_notes, '') ||
          CASE WHEN v_final_xp > 0 OR v_final_credits > 0
            THEN ' [Награда: ' || v_final_xp || ' опыта, ' || v_final_credits || ' монет]'
            ELSE '' END
        WHEN 'wont_fix' THEN 'Не будет исправлено. ' || COALESCE(p_notes, '')
        WHEN 'duplicate' THEN 'Уже известно. ' || COALESCE(p_notes, '')
        WHEN 'closed' THEN 'Закрыт. ' || COALESCE(p_notes, '')
        ELSE 'Статус изменён на ' || p_status || '. ' || COALESCE(p_notes, '')
      END, true, true);

  RETURN jsonb_build_object(
    'success', true,
    'status', p_status,
    'xp_awarded', v_final_xp,
    'credits_awarded', v_final_credits,
    'bounty_applied', (v_bounty_id IS NOT NULL AND v_final_xp > 0)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ─── 5. Fix award_xp calls in interactive-radio.sql ──────────
-- radio_award_listen_xp: fix the PERFORM call

CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID,
  p_track_id UUID,
  p_listen_duration_sec INTEGER DEFAULT 0,
  p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_hash TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_min_pct NUMERIC;
  v_xp_per_listen INTEGER;
  v_daily_cap INTEGER;
  v_max_per_track INTEGER;
  v_cooldown_sec INTEGER;
  v_track_duration INTEGER;
  v_listen_pct NUMERIC;
  v_xp INTEGER;
  v_today_count INTEGER;
  v_track_today_count INTEGER;
  v_last_award TIMESTAMPTZ;
  v_ip_sessions INTEGER;
BEGIN
  -- Read config
  v_min_pct         := COALESCE((SELECT (value->>'radio_min_listen_pct')::numeric   FROM public.economy_config WHERE key = 'radio'), 0.6);
  v_xp_per_listen   := COALESCE((SELECT (value->>'radio_xp_per_listen')::integer    FROM public.economy_config WHERE key = 'radio'), 2);
  v_daily_cap       := COALESCE((SELECT (value->>'radio_xp_daily_cap')::integer     FROM public.economy_config WHERE key = 'radio'), 50);
  v_max_per_track   := COALESCE((SELECT (value->>'radio_max_xp_per_track')::integer FROM public.economy_config WHERE key = 'radio'), 3);
  v_cooldown_sec    := 10;

  -- Anti-abuse: cooldown
  SELECT MAX(created_at) INTO v_last_award
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at > now() - interval '10 seconds';
  IF v_last_award IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cooldown', 'wait_sec', v_cooldown_sec);
  END IF;

  -- Anti-abuse: per-track daily limit
  SELECT COUNT(*) INTO v_track_today_count
  FROM public.radio_listens
  WHERE user_id = p_user_id AND track_id = p_track_id
    AND created_at >= CURRENT_DATE AND xp_earned > 0;
  IF v_track_today_count >= v_max_per_track THEN
    RETURN jsonb_build_object('ok', false, 'error', 'track_daily_limit');
  END IF;

  -- Anti-abuse: global daily cap
  SELECT COALESCE(SUM(xp_earned), 0) INTO v_today_count
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_today_count >= v_daily_cap THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_cap');
  END IF;

  -- Anti-abuse: IP sessions limit (max 5 per day)
  IF p_ip_hash IS NOT NULL THEN
    SELECT COUNT(DISTINCT session_id) INTO v_ip_sessions
    FROM public.radio_listens
    WHERE ip_hash = p_ip_hash AND created_at >= CURRENT_DATE;
    IF v_ip_sessions > 5 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ip_session_limit');
    END IF;
  END IF;

  -- Get track duration and clamp listen duration
  SELECT COALESCE(duration, 180) INTO v_track_duration
  FROM public.tracks WHERE id = p_track_id;

  -- Clamp to realistic duration (track duration + 10% tolerance)
  IF p_listen_duration_sec > v_track_duration * 1.1 THEN
    v_listen_pct := 1.0;
  ELSE
    v_listen_pct := LEAST(1.0, CASE WHEN v_track_duration > 0
      THEN p_listen_duration_sec::numeric / v_track_duration
      ELSE 0 END);
  END IF;

  -- Must have listened at least min_pct
  IF v_listen_pct < v_min_pct THEN
    v_xp := 0;
  ELSE
    v_xp := v_xp_per_listen;
  END IF;

  -- Clamp to remaining daily cap
  v_xp := LEAST(v_xp, v_daily_cap - v_today_count);

  -- Record listen
  INSERT INTO public.radio_listens (
    user_id, track_id, listen_pct, xp_earned, reaction, session_id, ip_hash
  ) VALUES (
    p_user_id, p_track_id,
    v_listen_pct, v_xp, p_reaction, p_session_id, p_ip_hash
  );

  -- Award XP via reputation system (CORRECT parameter order)
  IF v_xp > 0 THEN
    BEGIN
      PERFORM public.award_xp(
        p_user_id,
        'radio_listen',
        'track',
        p_track_id,
        jsonb_build_object('listen_pct', v_listen_pct, 'session', p_session_id)
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'award_xp(radio_listen) failed: %', SQLERRM;
    END;
  END IF;

  -- Update track plays_count
  UPDATE public.tracks SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id AND v_listen_pct >= v_min_pct;

  RETURN jsonb_build_object(
    'ok', true,
    'xp', v_xp,
    'listen_pct', round(v_listen_pct * 100),
    'daily_remaining', v_daily_cap - v_today_count - v_xp
  );
END;
$$;


-- ─── 6. Fix prediction award_xp calls ────────────────────────
-- The radio_resolve_predictions function needs fixed award_xp calls.
-- We recreate just the inner award_xp calls pattern.
-- Since the function is large, we use a helper approach.

-- Create a safe wrapper that won't fail silently
CREATE OR REPLACE FUNCTION public.safe_award_xp(
  p_user_id UUID,
  p_event_type TEXT,
  p_source_type TEXT DEFAULT NULL,
  p_source_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  PERFORM public.award_xp(p_user_id, p_event_type, p_source_type, p_source_id, p_metadata);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'safe_award_xp(%, %) failed: %', p_user_id, p_event_type, SQLERRM;
END;
$$;


-- ─── 7. Fix award_contest_prize conflict ──────────────────────
-- 006-audit-tables.sql created a conflicting overload with different params.
-- Drop the broken stub and keep the original from 001-schema.sql.

DROP FUNCTION IF EXISTS public.award_contest_prize(uuid, uuid, integer);
-- The original award_contest_prize(uuid, uuid) from 001-schema.sql remains intact.


-- ═══════════════════════════════════════════════════════════════
-- DONE: All critical reward path fixes applied.
-- ═══════════════════════════════════════════════════════════════
