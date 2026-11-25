-- Serialize QA rewards and notify the reporter after posting the reward.
CREATE OR REPLACE FUNCTION public.resolve_qa_ticket(p_ticket_id uuid, p_status text, p_notes text DEFAULT NULL::text, p_reward_xp integer DEFAULT 0, p_reward_credits integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO public
AS $function$
DECLARE
  v_admin_id UUID;
  v_reporter_id UUID;
  v_ticket_number TEXT;
  v_balance_after INTEGER;
  v_old_status TEXT;
  v_bounty_id UUID;
  v_severity TEXT;
  v_existing_reward_xp INTEGER;
  v_existing_reward_credits INTEGER;
  v_bounty RECORD;
  v_final_xp INTEGER;
  v_final_credits INTEGER;
  v_rep INTEGER;
  v_tier RECORD;
  v_rewards_config JSONB;
  v_should_grant_reward BOOLEAN;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- The gateway executes as authenticated; keep authorization inside the definer too.
  IF NOT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = v_admin_id AND role::text IN ('moderator', 'admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;

  SELECT reporter_id, ticket_number, status, bounty_id, severity, COALESCE(reward_xp, 0), COALESCE(reward_credits, 0)
    INTO v_reporter_id, v_ticket_number, v_old_status, v_bounty_id, v_severity, v_existing_reward_xp, v_existing_reward_credits
  FROM public.qa_tickets
  WHERE id = p_ticket_id
  FOR UPDATE;

  IF v_reporter_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ticket not found');
  END IF;

  v_final_xp := COALESCE(p_reward_xp, 0);
  v_final_credits := COALESCE(p_reward_credits, 0);
  IF v_final_xp < 0 OR v_final_credits < 0 THEN
    RAISE EXCEPTION 'Reward amounts cannot be negative' USING ERRCODE = '22023';
  END IF;

  IF v_bounty_id IS NOT NULL AND (v_final_xp = 0 AND v_final_credits = 0) THEN
    SELECT reward_xp, reward_credits, is_active, claimed_count, max_claims
      INTO v_bounty
    FROM public.qa_bounties
    WHERE id = v_bounty_id;

    IF v_bounty IS NOT NULL AND v_bounty.is_active AND v_bounty.claimed_count < v_bounty.max_claims THEN
      v_final_xp := v_bounty.reward_xp;
      v_final_credits := v_bounty.reward_credits;
    END IF;
  END IF;

  IF v_final_credits > 0 AND v_final_xp = 0 AND v_severity IS NOT NULL THEN
    SELECT value INTO v_rewards_config
    FROM public.qa_config
    WHERE key = 'rewards';

    IF v_rewards_config IS NOT NULL THEN
      v_final_xp := COALESCE((v_rewards_config->>(v_severity || '_xp'))::INTEGER, 0);
    END IF;
  END IF;

  v_should_grant_reward :=
    p_status = 'confirmed'
    AND COALESCE(v_existing_reward_xp, 0) = 0
    AND COALESCE(v_existing_reward_credits, 0) = 0
    AND (v_final_xp > 0 OR v_final_credits > 0)
    AND NOT public.is_user_blocked(v_reporter_id);

  UPDATE public.qa_tickets
  SET status = p_status,
      resolution_notes = COALESCE(p_notes, resolution_notes),
      resolved_by = CASE
        WHEN p_status IN ('fixed', 'wont_fix', 'duplicate', 'closed') THEN v_admin_id
        ELSE resolved_by
      END,
      resolved_at = CASE
        WHEN p_status IN ('fixed', 'wont_fix', 'duplicate', 'closed') THEN now()
        ELSE resolved_at
      END,
      reward_xp = CASE
        WHEN v_should_grant_reward THEN v_final_xp
        ELSE reward_xp
      END,
      reward_credits = CASE
        WHEN v_should_grant_reward THEN v_final_credits
        ELSE reward_credits
      END
  WHERE id = p_ticket_id;

  IF v_should_grant_reward THEN
    INSERT INTO public.qa_tester_stats (user_id, xp_earned, credits_earned)
    VALUES (v_reporter_id, v_final_xp, v_final_credits)
    ON CONFLICT (user_id) DO UPDATE SET
      xp_earned = qa_tester_stats.xp_earned + v_final_xp,
      credits_earned = qa_tester_stats.credits_earned + v_final_credits;

    IF v_final_xp > 0 THEN
      v_rep := LEAST(v_final_xp / 2, 10);

      INSERT INTO public.forum_user_stats (
        user_id,
        xp_total,
        xp_social,
        xp_daily_earned,
        xp_daily_date,
        reputation_score,
        last_activity_date,
        updated_at
      )
      VALUES (
        v_reporter_id,
        v_final_xp,
        v_final_xp,
        v_final_xp,
        CURRENT_DATE,
        v_rep,
        CURRENT_DATE,
        now()
      )
      ON CONFLICT (user_id) DO UPDATE SET
        xp_total = COALESCE(forum_user_stats.xp_total, 0) + v_final_xp,
        xp_social = COALESCE(forum_user_stats.xp_social, 0) + v_final_xp,
        xp_daily_earned = COALESCE(forum_user_stats.xp_daily_earned, 0) + v_final_xp,
        xp_daily_date = CURRENT_DATE,
        reputation_score = COALESCE(forum_user_stats.reputation_score, 0) + v_rep,
        last_activity_date = CURRENT_DATE,
        updated_at = now();

      SELECT *
        INTO v_tier
      FROM public.reputation_tiers
      WHERE min_xp <= (
        SELECT COALESCE(xp_total, 0)
        FROM public.forum_user_stats
        WHERE user_id = v_reporter_id
      )
      ORDER BY level DESC
      LIMIT 1;

      IF v_tier IS NOT NULL THEN
        UPDATE public.forum_user_stats
        SET tier = v_tier.key,
            vote_weight = v_tier.vote_weight,
            trust_level = v_tier.level
        WHERE user_id = v_reporter_id;
      END IF;

      INSERT INTO public.reputation_events (
        user_id,
        event_type,
        xp_delta,
        reputation_delta,
        category,
        source_type,
        source_id,
        metadata
      )
      VALUES (
        v_reporter_id,
        'qa_report_confirmed',
        v_final_xp,
        v_rep,
        'social',
        'qa_ticket',
        p_ticket_id,
        jsonb_build_object('xp_custom', v_final_xp, 'bounty_id', v_bounty_id)
      );
    END IF;

    IF v_final_credits > 0 THEN
      UPDATE public.profiles
      SET balance = COALESCE(balance, 0) + v_final_credits
      WHERE user_id = v_reporter_id
      RETURNING balance INTO v_balance_after;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Reporter profile not found';
      END IF;

      INSERT INTO public.balance_transactions (
        user_id, amount, type, description, reference_type, reference_id,
        balance_before, balance_after, metadata
      )
      VALUES (
        v_reporter_id, v_final_credits, 'qa_reward',
        'Награда за багрепорт ' || v_ticket_number, 'qa_ticket', p_ticket_id,
        v_balance_after - v_final_credits, v_balance_after,
        jsonb_build_object('ticket_number', v_ticket_number)
      );
    END IF;

    IF v_bounty_id IS NOT NULL THEN
      UPDATE public.qa_bounties
      SET claimed_count = claimed_count + 1
      WHERE id = v_bounty_id;

      UPDATE public.qa_bounties
      SET is_active = false
      WHERE id = v_bounty_id
        AND claimed_count >= max_claims;
    END IF;

    INSERT INTO public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id, link, metadata
    )
    VALUES (
      v_reporter_id, 'qa_reward_granted', 'Начислена награда за ' || v_ticket_number,
      concat_ws(' ',
        CASE WHEN v_final_credits > 0 THEN format('На баланс зачислено %s ₽.', v_final_credits) END,
        CASE WHEN v_final_xp > 0 THEN format('Начислено %s XP.', v_final_xp) END
      ),
      v_admin_id, 'qa_ticket', p_ticket_id, '/bug-reports?ticket=' || p_ticket_id::TEXT,
      jsonb_build_object(
        'ticket_number', v_ticket_number, 'reward_xp', v_final_xp,
        'reward_credits', v_final_credits, 'balance_after', v_balance_after
      )
    );
  END IF;

  IF p_status = 'confirmed' AND v_old_status IS DISTINCT FROM 'confirmed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_confirmed)
    VALUES (v_reporter_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET
      reports_confirmed = qa_tester_stats.reports_confirmed + 1;
  ELSIF p_status IN ('wont_fix', 'duplicate', 'closed')
    AND COALESCE(v_old_status, '') NOT IN ('confirmed', 'triaged', 'in_progress', 'fixed', 'wont_fix', 'duplicate', 'closed')
  THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_rejected)
    VALUES (v_reporter_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET
      reports_rejected = qa_tester_stats.reports_rejected + 1;
  END IF;

  PERFORM public.qa_update_tester_tier(v_reporter_id);

  INSERT INTO public.qa_comments (ticket_id, user_id, message, is_staff, is_system)
  VALUES (
    p_ticket_id,
    v_admin_id,
    CASE p_status
      WHEN 'confirmed' THEN 'Баг подтверждён. ' || COALESCE(p_notes, '')
      WHEN 'triaged' THEN 'Баг принят в план. ' || COALESCE(p_notes, '')
      WHEN 'in_progress' THEN 'Исправление началось. ' || COALESCE(p_notes, '')
      WHEN 'fixed' THEN 'Баг исправлен. ' || COALESCE(p_notes, '')
      WHEN 'wont_fix' THEN 'Не будет исправлено. ' || COALESCE(p_notes, '')
      WHEN 'duplicate' THEN 'Дубликат. ' || COALESCE(p_notes, '')
      WHEN 'closed' THEN 'Закрыт. ' || COALESCE(p_notes, '')
      ELSE 'Статус изменён на ' || p_status || '. ' || COALESCE(p_notes, '')
    END,
    true,
    true
  );

  RETURN jsonb_build_object(
    'success', true,
    'status', p_status,
    'reward_granted', v_should_grant_reward,
    'reward_xp', CASE WHEN v_should_grant_reward THEN v_final_xp ELSE v_existing_reward_xp END,
    'reward_credits', CASE WHEN v_should_grant_reward THEN v_final_credits ELSE v_existing_reward_credits END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_qa_ticket(uuid,text,text,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_qa_ticket(uuid,text,text,integer,integer) TO authenticated, service_role;

-- A balance change only needs to tell the owner to refetch the ledger and balance.
CREATE OR REPLACE FUNCTION public.notify_balance_transaction_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    PERFORM pg_notify('table_changes', jsonb_build_object(
      'schema', 'public', 'table', 'balance_transactions', 'type', 'INSERT',
      'record', jsonb_build_object('id', NEW.id, 'user_id', NEW.user_id)
    )::text);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_notify_balance_transactions
AFTER INSERT ON public.balance_transactions
FOR EACH ROW EXECUTE FUNCTION public.notify_balance_transaction_insert();
