--
-- PostgreSQL database dump
--

\restrict s7DlPx6cBEd4MBtZoyctFpHkBFR5znzBStgy9ipFlf88eGdDIuAyIvcnkLS0bIc

-- Dumped from database version 15.16
-- Dumped by pg_dump version 15.16

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA auth;


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: app_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.app_role AS ENUM (
    'admin',
    'moderator',
    'user',
    'super_admin'
);


--
-- Name: email(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.email() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT current_setting('request.jwt.claim.email', true);
$$;


--
-- Name: role(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.role() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(current_setting('request.jwt.claim.role', true), 'anon');
$$;


--
-- Name: uid(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID;
$$;


--
-- Name: accept_role_invitation(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.accept_role_invitation(_invitation_id uuid, _accept boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  inv record;
  caller_id uuid;
  result jsonb;
BEGIN
  caller_id := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO inv FROM public.role_invitations
  WHERE id = _invitation_id
    AND user_id = caller_id
    AND status = 'pending'
    AND (expires_at IS NULL OR expires_at > now());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found or expired';
  END IF;

  IF _accept THEN
    UPDATE public.role_invitations
    SET status = 'accepted', responded_at = now()
    WHERE id = _invitation_id;

    INSERT INTO public.user_roles (user_id, role)
    VALUES (caller_id, inv.role::app_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    IF inv.role = 'moderator' THEN
      INSERT INTO public.moderator_permissions (user_id, category_id, granted_by)
      SELECT caller_id, rip.category_id, inv.invited_by
      FROM public.role_invitation_permissions rip
      WHERE rip.invitation_id = _invitation_id
      ON CONFLICT (user_id, category_id) DO NOTHING;
    END IF;

    UPDATE public.profiles SET role = inv.role WHERE user_id = caller_id;

    INSERT INTO public.role_change_logs (user_id, changed_by, action, new_role, metadata)
    VALUES (caller_id, inv.invited_by, 'accepted', inv.role::app_role,
      jsonb_build_object('invitation_id', _invitation_id));

    result := jsonb_build_object('accepted', true, 'role', inv.role);
  ELSE
    UPDATE public.role_invitations
    SET status = 'declined', responded_at = now()
    WHERE id = _invitation_id;

    INSERT INTO public.role_change_logs (user_id, changed_by, action, metadata)
    VALUES (caller_id, inv.invited_by, 'declined',
      jsonb_build_object('invitation_id', _invitation_id, 'role', inv.role));

    result := jsonb_build_object('accepted', false, 'role', inv.role);
  END IF;

  RETURN result;
END;
$$;


--
-- Name: add_user_credits(uuid, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_user_credits(p_user_id uuid, p_amount integer, p_reason text DEFAULT '????????????????????'::text) RETURNS jsonb
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


--
-- Name: admin_add_xp(uuid, integer, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_add_xp(p_user_id uuid, p_xp_amount integer, p_reason text DEFAULT 'Ручное начисление администратором'::text, p_reputation_amount integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_admin_id UUID;
  v_rep INTEGER;
  v_new_xp INTEGER;
  v_new_rep INTEGER;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Not authenticated');
  END IF;

  IF NOT public.is_super_admin(v_admin_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Только супер-администратор может начислять XP вручную');
  END IF;

  IF p_xp_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Сумма XP должна быть положительной');
  END IF;

  v_rep := COALESCE(p_reputation_amount, LEAST(p_xp_amount / 2, 10));
  IF v_rep < 0 THEN v_rep := 0; END IF;

  -- Ensure user stats exist
  INSERT INTO public.forum_user_stats (user_id, xp_total)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  -- Add XP and reputation
  UPDATE public.forum_user_stats SET
    xp_total = COALESCE(xp_total, 0) + p_xp_amount,
    reputation_score = COALESCE(reputation_score, 0) + v_rep,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total, reputation_score INTO v_new_xp, v_new_rep;

  -- Log event
  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, metadata)
  VALUES (p_user_id, 'admin_bonus', p_xp_amount, v_rep, 'general',
    jsonb_build_object('reason', p_reason, 'admin_id', v_admin_id));

  -- Recalculate tier based on new XP
  UPDATE public.forum_user_stats fus SET
    tier = rt.key,
    vote_weight = rt.vote_weight,
    trust_level = rt.level
  FROM (
    SELECT key, vote_weight, level FROM public.reputation_tiers
    WHERE min_xp <= v_new_xp ORDER BY level DESC LIMIT 1
  ) rt
  WHERE fus.user_id = p_user_id;

  -- Recheck achievements
  PERFORM public.check_user_achievements(p_user_id);

  RETURN jsonb_build_object('ok', true, 'xp_added', p_xp_amount, 'rep_added', v_rep, 'new_xp', v_new_xp, 'new_reputation', v_new_rep);
END;
$$;


--
-- Name: approve_verification(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.approve_verification(_request_id text, _admin_id text, _action text, _rejection_reason text DEFAULT NULL::text, _admin_notes text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_req_id UUID := _request_id::uuid;
  v_adm_id UUID := _admin_id::uuid;
  v_request RECORD;
  v_type_label TEXT;
BEGIN
  IF NOT is_admin(v_adm_id) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  SELECT * INTO v_request
  FROM verification_requests
  WHERE id = v_req_id AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found or already processed';
  END IF;

  IF _action = 'approve' THEN
    UPDATE profiles SET
      is_verified = true,
      verified_at = now(),
      verified_by = v_adm_id,
      verification_type = v_request.type
    WHERE user_id = v_request.user_id;

    UPDATE verification_requests SET
      status = 'approved',
      reviewed_by = v_adm_id,
      reviewed_at = now()
    WHERE id = v_req_id;

    v_type_label := CASE v_request.type
      WHEN 'artist' THEN '??????????'
      WHEN 'creator' THEN '??????????????????'
      WHEN 'label' THEN '??????????'
      WHEN 'partner' THEN '??????????????'
      ELSE v_request.type
    END;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, v_adm_id,
      'verification_approved',
      '?????????????????????? ????????????????????????',
      '??????????????????????! ?????? ?????????????? ?????????????? ???????????? ' || v_type_label || '.',
      'verification', v_req_id
    );

    RETURN jsonb_build_object('status', 'approved', 'type', v_request.type);

  ELSIF _action = 'reject' THEN
    UPDATE verification_requests SET
      status = 'rejected',
      reviewed_by = v_adm_id,
      reviewed_at = now(),
      rejection_reason = _rejection_reason
    WHERE id = v_req_id;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, v_adm_id,
      'verification_rejected',
      '???????????? ???? ?????????????????????? ??????????????????',
      CASE WHEN _rejection_reason IS NOT NULL
        THEN '??????????????: ' || _rejection_reason
        ELSE '???????? ???????????? ???????? ??????????????????.'
      END,
      'verification', v_req_id
    );

    RETURN jsonb_build_object('status', 'rejected');
  ELSE
    RAISE EXCEPTION 'Invalid action: %', _action;
  END IF;
END;
$$;


--
-- Name: award_contest_prize(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.award_contest_prize(_winner_id uuid, _contest_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_contest RECORD;
  v_winner RECORD;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  
  SELECT id, title, prize_amount INTO v_contest 
  FROM public.contests WHERE id = _contest_id;
  
  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;
  
  SELECT * INTO v_winner 
  FROM public.contest_winners 
  WHERE id = _winner_id AND contest_id = _contest_id;
  
  IF v_winner IS NULL THEN
    RAISE EXCEPTION 'Победитель не найден';
  END IF;
  
  IF v_winner.prize_awarded THEN
    RAISE EXCEPTION 'Приз уже выплачен';
  END IF;
  
  IF v_winner.place = 1 AND v_contest.prize_amount > 0 THEN
    UPDATE public.profiles 
    SET balance = balance + v_contest.prize_amount
    WHERE user_id = v_winner.user_id;
    
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_winner.user_id,
      'prize_awarded',
      'Приз начислен!',
      'На ваш баланс зачислено ' || v_contest.prize_amount || ' за победу в конкурсе "' || v_contest.title || '"',
      'contest',
      _contest_id
    );

    -- Log balance transaction
    BEGIN
      INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id)
      VALUES (v_winner.user_id, v_contest.prize_amount, 'contest_prize', 'Приз конкурса "' || v_contest.title || '"', 'contest', _contest_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;
  
  UPDATE public.contest_winners 
  SET prize_awarded = true 
  WHERE id = _winner_id;
  
  RETURN true;
END;
$$;


--
-- Name: award_xp(uuid, text, text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.award_xp(p_user_id uuid, p_event_type text, p_source_type text DEFAULT NULL::text, p_source_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_config RECORD;
  v_stats RECORD;
  v_tier RECORD;
  v_daily_count INTEGER;
  v_cooldown_ok BOOLEAN;
  v_xp INTEGER;
  v_rep INTEGER;
  v_tier_changed BOOLEAN := false;
  v_achievements_earned INTEGER := 0;
  v_inflation JSONB;
  v_global_daily_cap INTEGER;
  v_global_weekly_soft INTEGER;
  v_weekly_multiplier NUMERIC;
  v_global_monthly_hard INTEGER;
  v_current_daily_xp INTEGER;
  v_current_weekly_xp INTEGER;
  v_current_monthly_xp INTEGER;
BEGIN
  -- ????????? P0 FIX: Block check ?????????
  IF public.is_user_blocked(p_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_blocked');
  END IF;

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

  -- Global XP caps from economy_config
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
  v_xp := LEAST(v_xp, v_global_daily_cap - v_current_daily_xp);

  -- Weekly soft cap
  SELECT COALESCE(SUM(xp_delta), 0) INTO v_current_weekly_xp
  FROM public.reputation_events
  WHERE user_id = p_user_id AND xp_delta > 0
    AND created_at >= date_trunc('week', CURRENT_DATE);
  IF v_current_weekly_xp >= v_global_weekly_soft THEN
    v_xp := GREATEST(1, (v_xp * v_weekly_multiplier)::integer);
  END IF;

  -- Monthly hard cap
  SELECT COALESCE(SUM(xp_delta), 0) INTO v_current_monthly_xp
  FROM public.reputation_events
  WHERE user_id = p_user_id AND xp_delta > 0
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

    INSERT INTO public.notifications (user_id, type, title, message, data)
    VALUES (p_user_id, 'achievement', '?????????? ????????????!',
      '??????????????????????! ???? ???????????????? ???????????? ??' || v_tier.name_ru || '??',
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


--
-- Name: block_user(uuid, text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.block_user(p_user_id uuid, p_reason text DEFAULT ''::text, p_blocked_by uuid DEFAULT NULL::uuid, p_duration text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.user_blocks (user_id, blocked_by, reason, expires_at)
  VALUES (p_user_id, p_blocked_by, p_reason,
    CASE WHEN p_duration IS NOT NULL THEN now() + p_duration::interval ELSE NULL END);

  UPDATE public.profiles
  SET is_blocked = true, blocked_at = now(), blocked_reason = p_reason, blocked_by = p_blocked_by
  WHERE user_id = p_user_id;
END;
$$;


--
-- Name: calculate_track_quality(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_track_quality(p_track_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_track RECORD;
  v_plays INTEGER;
  v_likes INTEGER;
  v_comments INTEGER;
  v_unique_listeners INTEGER;
  v_engagement NUMERIC;
  v_completion NUMERIC;
  v_save NUMERIC;
  v_score NUMERIC;
  v_config JSONB;
  v_weights JSONB;
BEGIN
  SELECT value INTO v_config FROM public.economy_config WHERE key = 'quality_gate';
  v_weights := v_config->'score_weights';

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Track not found'); END IF;

  v_plays := COALESCE(v_track.plays_count, 0);
  v_likes := COALESCE(v_track.likes_count, 0);

  SELECT COUNT(*) INTO v_comments FROM public.track_comments WHERE track_id = p_track_id;

  -- Approximate unique listeners (plays with diminishing returns)
  v_unique_listeners := LEAST(v_plays, GREATEST(1, v_plays * 0.7)::INTEGER);

  -- Engagement rate: interactions / plays
  v_engagement := CASE WHEN v_plays > 0
    THEN LEAST(1.0, (v_likes + v_comments)::NUMERIC / v_plays)
    ELSE 0 END;

  -- Completion rate: approximate based on engagement
  v_completion := CASE WHEN v_plays > 10
    THEN LEAST(1.0, 0.5 + v_engagement * 0.5)
    ELSE 0.5 END;

  -- Save rate: approximate
  v_save := CASE WHEN v_plays > 0
    THEN LEAST(1.0, v_likes::NUMERIC / v_plays * 0.5)
    ELSE 0 END;

  -- Calculate weighted score (0-10 scale)
  v_score := LEAST(10.0, (
    v_engagement * COALESCE((v_weights->>'engagement_rate')::NUMERIC, 4.0) +
    v_completion * COALESCE((v_weights->>'completion_rate')::NUMERIC, 3.0) +
    LEAST(1.0, v_unique_listeners::NUMERIC / 50.0) * COALESCE((v_weights->>'unique_listeners')::NUMERIC, 2.0) +
    v_save * COALESCE((v_weights->>'save_rate')::NUMERIC, 1.0)
  ));

  -- Upsert quality score
  INSERT INTO public.track_quality_scores (
    track_id, user_id, engagement_rate, completion_rate,
    unique_listeners_48h, save_rate, quality_score,
    eligible_for_feed, eligible_for_attribution,
    flagged_as_spam, metrics_collected_at
  ) VALUES (
    p_track_id, v_track.user_id, v_engagement, v_completion,
    v_unique_listeners, v_save, v_score,
    v_score >= COALESCE((v_config->>'min_score_for_feed')::NUMERIC, 3.0),
    v_score >= COALESCE((v_config->>'min_score_for_attribution')::NUMERIC, 3.0),
    v_score < COALESCE((v_config->>'spam_threshold')::NUMERIC, 1.5),
    now()
  )
  ON CONFLICT (track_id) DO UPDATE SET
    engagement_rate = EXCLUDED.engagement_rate,
    completion_rate = EXCLUDED.completion_rate,
    unique_listeners_48h = EXCLUDED.unique_listeners_48h,
    save_rate = EXCLUDED.save_rate,
    quality_score = EXCLUDED.quality_score,
    eligible_for_feed = EXCLUDED.eligible_for_feed,
    eligible_for_attribution = EXCLUDED.eligible_for_attribution,
    flagged_as_spam = EXCLUDED.flagged_as_spam,
    metrics_collected_at = EXCLUDED.metrics_collected_at,
    updated_at = now();

  RETURN jsonb_build_object(
    'track_id', p_track_id,
    'quality_score', v_score,
    'engagement_rate', v_engagement,
    'completion_rate', v_completion,
    'unique_listeners', v_unique_listeners,
    'eligible_for_feed', v_score >= COALESCE((v_config->>'min_score_for_feed')::NUMERIC, 3.0),
    'eligible_for_attribution', v_score >= COALESCE((v_config->>'min_score_for_attribution')::NUMERIC, 3.0)
  );
END;
$$;


--
-- Name: check_achievements_after_finalize(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_achievements_after_finalize() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: check_contest_achievements(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_contest_achievements(p_user_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: check_user_achievements(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_user_achievements(p_user_id uuid) RETURNS integer
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


--
-- Name: check_voting_eligibility(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_voting_eligibility() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_account_created_at TIMESTAMP WITH TIME ZONE;
  v_min_age_hours INTEGER;
  v_rate_limit INTEGER;
  v_recent_votes INTEGER;
BEGIN
  -- 1. Check account age
  SELECT created_at INTO v_account_created_at
  FROM auth.users WHERE id = NEW.user_id;

  SELECT COALESCE((SELECT value::integer FROM public.settings WHERE key = 'voting_min_account_age_hours'), 24)
  INTO v_min_age_hours;

  IF v_account_created_at IS NOT NULL AND
     v_account_created_at > now() - (v_min_age_hours || ' hours')::interval THEN
    RAISE EXCEPTION 'Account must be at least % hours old to vote', v_min_age_hours;
  END IF;

  -- 2. Check rate limit
  SELECT COALESCE((SELECT value::integer FROM public.settings WHERE key = 'voting_rate_limit_per_hour'), 20)
  INTO v_rate_limit;

  SELECT COUNT(*) INTO v_recent_votes
  FROM public.track_votes
  WHERE user_id = NEW.user_id AND created_at > now() - interval '1 hour';

  IF v_recent_votes >= v_rate_limit THEN
    RAISE EXCEPTION 'Vote rate limit exceeded: max % per hour', v_rate_limit;
  END IF;

  -- 3. Prevent self-voting
  IF EXISTS (SELECT 1 FROM public.tracks WHERE id = NEW.track_id AND user_id = NEW.user_id) THEN
    RAISE EXCEPTION 'Cannot vote on your own track';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: cleanup_old_logs(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_old_logs(p_days integer DEFAULT 30) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  deleted integer := 0;
  cnt integer;
BEGIN
  DELETE FROM public.error_logs WHERE created_at < now() - (p_days || ' days')::interval;
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  DELETE FROM public.generation_logs WHERE created_at < now() - (p_days || ' days')::interval AND status IN ('completed', 'failed');
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  DELETE FROM public.performance_alerts WHERE created_at < now() - (p_days || ' days')::interval AND resolved = true;
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  RETURN deleted;
END;
$$;


--
-- Name: close_admin_conversation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_admin_conversation(p_conversation_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  IF NOT is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Only admins can close conversations';
  END IF;
  
  UPDATE conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found or already closed';
  END IF;
END;
$$;


--
-- Name: close_voting_topic_on_rejection(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_voting_topic_on_rejection(p_track_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.forum_topics SET is_locked = true WHERE track_id = p_track_id;
END;
$$;


--
-- Name: create_admin_conversation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_admin_conversation(p_target_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_admin_id uuid;
  v_conversation_id uuid;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT is_admin(v_admin_id) THEN
    RAISE EXCEPTION 'Only admins can create admin conversations';
  END IF;

  -- Ищем существующий активный admin_support диалог с этим пользователем
  SELECT c.id INTO v_conversation_id
  FROM conversations c
  JOIN conversation_participants cp1 ON cp1.conversation_id = c.id AND cp1.user_id = p_target_user_id
  JOIN conversation_participants cp2 ON cp2.conversation_id = c.id AND cp2.user_id = v_admin_id
  WHERE c.type = 'admin_support'
    AND c.status != 'closed'
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;

  -- Создаём новый диалог
  INSERT INTO conversations (type, status)
  VALUES ('admin_support', 'active')
  RETURNING id INTO v_conversation_id;

  -- Добавляем участников (избегаем дубликата, если admin = target, напр. при имперсонации)
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES (v_conversation_id, v_admin_id);
  IF v_admin_id IS DISTINCT FROM p_target_user_id THEN
    INSERT INTO conversation_participants (conversation_id, user_id)
    VALUES (v_conversation_id, p_target_user_id);
  END IF;

  RETURN v_conversation_id;
END;
$$;


--
-- Name: create_conversation_with_user(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_conversation_with_user(p_other_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_conversation_id uuid;
  v_current_user_id uuid;
BEGIN
  v_current_user_id := auth.uid();
  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  
  -- Ищем существующий direct-диалог между двумя пользователями
  SELECT cp1.conversation_id INTO v_conversation_id
  FROM conversation_participants cp1
  JOIN conversation_participants cp2 ON cp1.conversation_id = cp2.conversation_id
  JOIN conversations c ON c.id = cp1.conversation_id
  WHERE cp1.user_id = v_current_user_id 
    AND cp2.user_id = p_other_user_id
    AND c.type = 'direct'
  LIMIT 1;
  
  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;
  
  -- Создаём новый диалог
  INSERT INTO conversations (type) VALUES ('direct')
  RETURNING id INTO v_conversation_id;
  
  -- Добавляем обоих участников
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES 
    (v_conversation_id, v_current_user_id),
    (v_conversation_id, p_other_user_id);
  
  RETURN v_conversation_id;
END;
$$;


--
-- Name: create_voting_forum_topic(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_voting_forum_topic(p_track_id uuid, p_moderator_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_topic_id uuid;
  v_track record;
  v_category_id uuid;
  v_title text;
  v_content text;
BEGIN
  -- Get track info
  SELECT id, title, user_id, description, cover_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found';
  END IF;

  -- Find or create a voting category
  SELECT id INTO v_category_id
  FROM public.forum_categories
  WHERE slug = 'news'
  LIMIT 1;

  -- If no category found, use the first one
  IF v_category_id IS NULL THEN
    SELECT id INTO v_category_id
    FROM public.forum_categories
    ORDER BY sort_order LIMIT 1;
  END IF;

  -- Build title and content
  v_title := '🗳️ Голосование: ' || COALESCE(v_track.title, 'Без названия');
  v_content := '**Трек отправлен на публичное голосование.**' || E'\n\n' ||
    'Послушайте и проголосуйте — ваш голос важен!' || E'\n\n' ||
    '🎵 **' || COALESCE(v_track.title, 'Без названия') || '**';

  -- Create pinned topic
  INSERT INTO public.forum_topics (
    user_id, category_id, title, content, is_pinned, is_locked, tags
  )
  VALUES (
    p_moderator_id, v_category_id, v_title, v_content, true, false, ARRAY['voting']
  )
  RETURNING id INTO v_topic_id;

  -- Link topic to track
  UPDATE public.tracks
  SET forum_topic_id = v_topic_id
  WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;


--
-- Name: deduct_user_xp(uuid, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.deduct_user_xp(p_user_id uuid, p_amount integer, p_reason text DEFAULT 'penalty'::text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_new_xp INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Только администратор может списывать XP');
  END IF;

  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_must_be_positive');
  END IF;

  INSERT INTO public.forum_user_stats (user_id, xp_total)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.forum_user_stats
  SET xp_total = GREATEST(0, COALESCE(xp_total, 0) - p_amount),
      reputation_score = GREATEST(0, COALESCE(reputation_score, 0) - LEAST(p_amount / 2, 10)),
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_xp;

  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, source_type, metadata)
  VALUES (p_user_id, 'admin_deduct', -p_amount, -LEAST(p_amount / 2, 10), 'general', 'admin',
    p_metadata || jsonb_build_object('reason', p_reason));

  -- Пересчёт tier
  UPDATE public.forum_user_stats fus SET
    tier = rt.key,
    vote_weight = rt.vote_weight,
    trust_level = rt.level
  FROM (
    SELECT key, vote_weight, level FROM public.reputation_tiers
    WHERE min_xp <= v_new_xp ORDER BY level DESC LIMIT 1
  ) rt
  WHERE fus.user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'xp_deducted', p_amount, 'new_xp', v_new_xp);
END;
$$;


--
-- Name: delete_forum_topic_cascade(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_forum_topic_cascade(p_topic_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM public.forum_posts WHERE topic_id = p_topic_id;
  DELETE FROM public.forum_topics WHERE id = p_topic_id;
END;
$$;


--
-- Name: finalize_contest(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_contest(p_contest_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: finalize_contest_winners(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_contest_winners(p_contest_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.contests SET status = 'completed', updated_at = now() WHERE id = p_contest_id;
END;
$$;


--
-- Name: find_similar_qa_tickets(text, text, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_similar_qa_tickets(p_title text, p_category text DEFAULT NULL::text, p_threshold numeric DEFAULT 0.3, p_limit integer DEFAULT 5) RETURNS TABLE(id uuid, ticket_number text, title text, status text, category text, severity text, similarity_score numeric, upvotes integer, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id,
    t.ticket_number,
    t.title,
    t.status,
    t.category,
    t.severity,
    ROUND(similarity(t.title, p_title)::NUMERIC, 3) AS similarity_score,
    t.upvotes,
    t.created_at
  FROM public.qa_tickets t
  WHERE similarity(t.title, p_title) > p_threshold
    AND t.status NOT IN ('closed', 'duplicate')
    AND (p_category IS NULL OR t.category = p_category)
  ORDER BY similarity(t.title, p_title) DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: find_user_by_short_id(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_user_by_short_id(short_id text) RETURNS TABLE(user_id uuid, username text, display_name text, avatar_url text)
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT p.user_id, p.username, p.username as display_name, p.avatar_url
  FROM public.profiles p
  WHERE p.user_id::text LIKE find_user_by_short_id.short_id || '%'
  LIMIT 1;
$$;


--
-- Name: fn_add_xp(uuid, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_add_xp(p_user_id uuid, p_amount numeric, p_category text DEFAULT 'forum'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: forum_authority_leaderboard(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_authority_leaderboard(p_limit integer DEFAULT 20) RETURNS TABLE(user_id uuid, username text, avatar_url text, authority_score numeric, authority_tier text, content_quality_avg numeric, solutions_count integer, citations_received integer, expertise_tags text[])
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT s.user_id, p.username, p.avatar_url,
    s.authority_score, s.authority_tier,
    s.content_quality_avg, s.solutions_count,
    s.citations_received, s.expertise_tags
  FROM public.forum_user_stats s
  LEFT JOIN public.profiles p ON p.user_id = s.user_id
  WHERE s.authority_score > 0
  ORDER BY s.authority_score DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: forum_boost_topic(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_boost_topic(p_topic_id uuid, p_boost_type text DEFAULT 'standard'::text, p_duration_hours integer DEFAULT 24) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id UUID;
  v_cost INTEGER;
  v_multiplier NUMERIC;
  v_balance INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- Determine cost
  v_cost := CASE p_boost_type
    WHEN 'standard' THEN 5
    WHEN 'premium' THEN 15
    WHEN 'mega' THEN 30
    ELSE 5 END;
  v_multiplier := CASE p_boost_type
    WHEN 'standard' THEN 1.5
    WHEN 'premium' THEN 3.0
    WHEN 'mega' THEN 5.0
    ELSE 1.5 END;

  -- Check balance (from profiles.credits)
  SELECT COALESCE(credits, 0) INTO v_balance FROM public.profiles WHERE user_id = v_user_id;
  IF v_balance < v_cost THEN
    RETURN jsonb_build_object('success', false, 'error', 'Insufficient credits', 'required', v_cost, 'balance', v_balance);
  END IF;

  -- Deduct credits
  UPDATE public.profiles SET credits = credits - v_cost WHERE user_id = v_user_id;

  -- Create boost
  INSERT INTO public.forum_topic_boosts (topic_id, boosted_by, boost_type, credits_spent, boost_multiplier, ends_at)
    VALUES (p_topic_id, v_user_id, p_boost_type, v_cost, v_multiplier, now() + (p_duration_hours || ' hours')::INTERVAL);

  -- Bump topic
  UPDATE public.forum_topics SET bumped_at = now() WHERE id = p_topic_id;

  RETURN jsonb_build_object('success', true, 'cost', v_cost, 'multiplier', v_multiplier, 'hours', p_duration_hours);
END;
$$;


--
-- Name: forum_calculate_content_quality(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_calculate_content_quality(p_content_type text, p_content_id uuid) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_content TEXT;
  v_author_id UUID;
  v_word_count INTEGER;
  v_depth NUMERIC := 0;
  v_usefulness NUMERIC := 0;
  v_engagement NUMERIC := 0;
  v_uniqueness NUMERIC := 0;
  v_overall NUMERIC := 0;
  v_votes_score INTEGER := 0;
  v_is_solution BOOLEAN := false;
  v_weighted_votes NUMERIC := 0;
  v_has_code BOOLEAN := false;
  v_has_images BOOLEAN := false;
  v_has_links BOOLEAN := false;
BEGIN
  IF p_content_type = 'topic' THEN
    SELECT content, user_id, votes_score, is_solved
      INTO v_content, v_author_id, v_votes_score, v_is_solution
      FROM public.forum_topics WHERE id = p_content_id;
  ELSIF p_content_type = 'post' THEN
    SELECT content, user_id, votes_score, is_solution
      INTO v_content, v_author_id, v_votes_score, v_is_solution
      FROM public.forum_posts WHERE id = p_content_id;
  END IF;

  IF v_content IS NULL THEN RETURN 0; END IF;

  -- Word count
  v_word_count := array_length(regexp_split_to_array(trim(v_content), '\s+'), 1);

  -- Depth score (0-10): based on length and structure
  v_depth := LEAST(10, (v_word_count::NUMERIC / 50.0) * 3
    + CASE WHEN v_content LIKE '%```%' THEN 2 ELSE 0 END
    + CASE WHEN v_content LIKE '%http%' THEN 1 ELSE 0 END
    + CASE WHEN v_content LIKE '%![%' THEN 1.5 ELSE 0 END
    + CASE WHEN v_word_count > 200 THEN 2 ELSE 0 END);

  v_has_code := v_content LIKE '%```%';
  v_has_images := v_content LIKE '%![%' OR v_content LIKE '%<img%';
  v_has_links := v_content LIKE '%http%';

  -- Usefulness (0-10): based on votes and solution status
  v_usefulness := LEAST(10, GREATEST(0, v_votes_score) * 2
    + CASE WHEN v_is_solution THEN 5 ELSE 0 END);

  -- Weighted votes (high-authority voters count more)
  SELECT COALESCE(SUM(
    CASE WHEN fus.authority_score > 50 THEN 2.0
         WHEN fus.authority_score > 20 THEN 1.5
         ELSE 1.0 END
  ), 0) INTO v_weighted_votes
  FROM public.forum_post_votes fpv
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = fpv.user_id
  WHERE (p_content_type = 'post' AND fpv.post_id = p_content_id)
     OR (p_content_type = 'topic' AND fpv.topic_id = p_content_id);

  -- Engagement (0-10)
  v_engagement := LEAST(10, v_weighted_votes * 1.5);

  -- Uniqueness placeholder (would need NLP in production)
  v_uniqueness := LEAST(10, v_depth * 0.5 + CASE WHEN v_has_code THEN 2 ELSE 0 END);

  -- Overall quality (weighted average)
  v_overall := ROUND((v_depth * 0.3 + v_usefulness * 0.35 + v_engagement * 0.2 + v_uniqueness * 0.15)::NUMERIC, 2);

  -- Upsert quality record
  INSERT INTO public.forum_content_quality (content_type, content_id, author_id,
    depth_score, usefulness_score, engagement_score, uniqueness_score, overall_quality,
    word_count, has_code_blocks, has_images, has_links, weighted_votes,
    solution_bonus, computed_at)
  VALUES (p_content_type, p_content_id, v_author_id,
    v_depth, v_usefulness, v_engagement, v_uniqueness, v_overall,
    v_word_count, v_has_code, v_has_images, v_has_links, v_weighted_votes,
    CASE WHEN v_is_solution THEN 5 ELSE 0 END, now())
  ON CONFLICT (content_type, content_id) DO UPDATE SET
    depth_score = EXCLUDED.depth_score,
    usefulness_score = EXCLUDED.usefulness_score,
    engagement_score = EXCLUDED.engagement_score,
    uniqueness_score = EXCLUDED.uniqueness_score,
    overall_quality = EXCLUDED.overall_quality,
    word_count = EXCLUDED.word_count,
    has_code_blocks = EXCLUDED.has_code_blocks,
    has_images = EXCLUDED.has_images,
    has_links = EXCLUDED.has_links,
    weighted_votes = EXCLUDED.weighted_votes,
    solution_bonus = EXCLUDED.solution_bonus,
    computed_at = now();

  RETURN v_overall;
END;
$$;


--
-- Name: forum_find_similar_topics(text, uuid, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_find_similar_topics(p_title text, p_category_id uuid DEFAULT NULL::uuid, p_threshold numeric DEFAULT 0.25, p_limit integer DEFAULT 5) RETURNS TABLE(id uuid, title text, slug text, category_id uuid, status text, votes_score integer, is_solved boolean, similarity numeric, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT t.id, t.title, t.slug, t.category_id,
    CASE WHEN t.is_hidden THEN 'hidden' WHEN t.is_locked THEN 'locked' ELSE 'active' END,
    t.votes_score, t.is_solved,
    ROUND(similarity(t.title, p_title)::NUMERIC, 3),
    t.created_at
  FROM public.forum_topics t
  WHERE similarity(t.title, p_title) > p_threshold
    AND NOT t.is_hidden
    AND (p_category_id IS NULL OR t.category_id = p_category_id)
  ORDER BY similarity(t.title, p_title) DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: forum_get_hub_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_get_hub_stats() RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_articles', (SELECT COUNT(*) FROM public.forum_knowledge_articles WHERE status = 'published'),
    'draft_articles', (SELECT COUNT(*) FROM public.forum_knowledge_articles WHERE status = 'draft'),
    'total_citations', (SELECT COUNT(*) FROM public.forum_citations),
    'active_boosts', (SELECT COUNT(*) FROM public.forum_topic_boosts WHERE is_active AND ends_at > now()),
    'total_boost_revenue', (SELECT COALESCE(SUM(credits_spent), 0) FROM public.forum_topic_boosts),
    'avg_content_quality', (SELECT ROUND(COALESCE(AVG(overall_quality), 0)::NUMERIC, 2) FROM public.forum_content_quality),
    'high_quality_count', (SELECT COUNT(*) FROM public.forum_content_quality WHERE overall_quality >= 7),
    'mentors_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'mentor'),
    'moderators_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'moderator'),
    'contributors_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'contributor'),
    'clusters_count', (SELECT COUNT(*) FROM public.forum_topic_clusters),
    'premium_content', (SELECT COUNT(*) FROM public.forum_premium_content WHERE is_active)
  ) INTO v_result;
  RETURN v_result;
END;
$$;


--
-- Name: forum_get_leaderboard(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_get_leaderboard(p_limit integer DEFAULT 10) RETURNS TABLE(user_id uuid, username text, avatar_url text, reputation integer, posts_count integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
    SELECT fs.user_id, p.username, p.avatar_url, fs.reputation, fs.posts_count
    FROM public.forum_user_stats fs
    LEFT JOIN public.profiles p ON p.user_id = fs.user_id
    ORDER BY fs.reputation DESC
    LIMIT p_limit;
END;
$$;


--
-- Name: forum_get_user_profile(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_get_user_profile(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'user_id', fs.user_id,
    'topics_count', fs.topics_count,
    'posts_count', fs.posts_count,
    'likes_received', fs.likes_received,
    'reputation', fs.reputation,
    'trust_level', fs.trust_level,
    'solutions_count', fs.solutions_count
  ) INTO result
  FROM public.forum_user_stats fs
  WHERE fs.user_id = p_user_id;

  RETURN COALESCE(result, jsonb_build_object(
    'user_id', p_user_id, 'topics_count', 0, 'posts_count', 0,
    'likes_received', 0, 'reputation', 0, 'trust_level', 0, 'solutions_count', 0
  ));
END;
$$;


--
-- Name: forum_increment_topic_views(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_increment_topic_views(p_topic_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.forum_topics SET views_count = views_count + 1 WHERE id = p_topic_id;
END;
$$;


--
-- Name: forum_mark_read(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_mark_read(p_user_id uuid, p_topic_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.forum_user_reads (user_id, topic_id, last_read_at)
  VALUES (p_user_id, p_topic_id, now())
  ON CONFLICT (user_id, topic_id) DO UPDATE SET last_read_at = now();
END;
$$;


--
-- Name: forum_mark_solution(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.forum_posts SET is_solution = true WHERE id = p_post_id;
  UPDATE public.forum_topics SET is_solved = true WHERE id = p_topic_id;
END;
$$;


--
-- Name: forum_moderate_promo(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_moderate_promo(p_promo_id uuid, p_action text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF p_action = 'approve' THEN
    UPDATE public.forum_promo_slots SET is_active = true WHERE id = p_promo_id;
  ELSIF p_action = 'reject' THEN
    DELETE FROM public.forum_promo_slots WHERE id = p_promo_id;
  END IF;
END;
$$;


--
-- Name: forum_recalculate_authority(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_recalculate_authority(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_quality_avg NUMERIC;
  v_solutions INTEGER;
  v_citations INTEGER;
  v_score NUMERIC;
  v_tier TEXT;
  v_can_articles BOOLEAN;
  v_can_boost BOOLEAN;
  v_expertise TEXT[];
BEGIN
  -- Average content quality
  SELECT COALESCE(AVG(overall_quality), 0) INTO v_quality_avg
    FROM public.forum_content_quality WHERE author_id = p_user_id;

  -- Solutions count
  SELECT COALESCE(solutions_count, 0) INTO v_solutions
    FROM public.forum_user_stats WHERE user_id = p_user_id;

  -- Citations
  SELECT COUNT(*) INTO v_citations
    FROM public.forum_citations c
    JOIN public.forum_knowledge_articles a ON a.id = c.article_id
    WHERE a.author_id = p_user_id;

  -- Expertise tags (top tags by quality)
  SELECT COALESCE(array_agg(t.name ORDER BY cq.overall_quality DESC), '{}')
    INTO v_expertise
    FROM (
      SELECT DISTINCT unnest(ft.tags) AS tag_name, ft.id AS topic_id
      FROM public.forum_topics ft WHERE ft.user_id = p_user_id AND ft.tags IS NOT NULL
    ) tagged
    JOIN public.forum_tags t ON t.name = tagged.tag_name
    JOIN public.forum_content_quality cq ON cq.content_id = tagged.topic_id AND cq.content_type = 'topic'
    LIMIT 5;

  -- Authority score
  v_score := ROUND((
    v_quality_avg * 10
    + v_solutions * 5
    + v_citations * 3
    + COALESCE((SELECT reputation_score FROM public.forum_user_stats WHERE user_id = p_user_id), 0) * 0.1
  )::NUMERIC, 2);

  -- Authority tier
  v_tier := CASE
    WHEN v_score >= 200 THEN 'moderator'
    WHEN v_score >= 100 THEN 'mentor'
    WHEN v_score >= 30 THEN 'contributor'
    ELSE 'reader'
  END;

  v_can_articles := v_score >= 50;
  v_can_boost := v_score >= 20;

  -- Update user stats
  UPDATE public.forum_user_stats SET
    authority_score = v_score,
    authority_tier = v_tier,
    content_quality_avg = v_quality_avg,
    citations_received = v_citations,
    expertise_tags = v_expertise,
    can_create_articles = v_can_articles,
    can_boost_topics = v_can_boost,
    authority_updated_at = now()
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'score', v_score, 'tier', v_tier,
    'quality_avg', v_quality_avg, 'solutions', v_solutions,
    'citations', v_citations, 'expertise', v_expertise
  );
END;
$$;


--
-- Name: forum_search(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_search(p_query text, p_limit integer DEFAULT 20) RETURNS TABLE(id uuid, title text, content text, type text, created_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY (
    SELECT t.id, t.title, t.content, 'topic'::text, t.created_at
    FROM public.forum_topics t
    WHERE t.title ILIKE '%' || p_query || '%' OR t.content ILIKE '%' || p_query || '%'
    UNION ALL
    SELECT p.id, ''::text, p.content, 'post'::text, p.created_at
    FROM public.forum_posts p
    WHERE p.content ILIKE '%' || p_query || '%'
  ) ORDER BY created_at DESC LIMIT p_limit;
END;
$$;


--
-- Name: forum_update_category_on_topic(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_update_category_on_topic() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.forum_categories
    SET topics_count = topics_count + 1, updated_at = now()
    WHERE id = NEW.category_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.forum_categories
    SET topics_count = GREATEST(topics_count - 1, 0), updated_at = now()
    WHERE id = OLD.category_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: forum_update_topic_on_post(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_update_topic_on_post() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.forum_topics
    SET posts_count = posts_count + 1,
        last_post_at = NEW.created_at,
        last_post_user_id = NEW.user_id,
        bumped_at = NEW.created_at,
        updated_at = now()
    WHERE id = NEW.topic_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.forum_topics
    SET posts_count = GREATEST(posts_count - 1, 0),
        updated_at = now()
    WHERE id = OLD.topic_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: forum_update_user_stats_on_post(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_update_user_stats_on_post() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.forum_user_stats (user_id, posts_count, reputation, last_active_at)
  VALUES (NEW.user_id, 1, 1, now())
  ON CONFLICT (user_id) DO UPDATE SET
    posts_count = forum_user_stats.posts_count + 1,
    reputation = forum_user_stats.reputation + 1,
    last_active_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: forum_update_user_stats_on_topic(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_update_user_stats_on_topic() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.forum_user_stats (user_id, topics_count, reputation, last_active_at)
  VALUES (NEW.user_id, 1, 2, now())
  ON CONFLICT (user_id) DO UPDATE SET
    topics_count = forum_user_stats.topics_count + 1,
    reputation = forum_user_stats.reputation + 2,
    last_active_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: forum_user_is_banned(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forum_user_is_banned(p_user_id uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.forum_user_bans
    WHERE user_id = p_user_id
      AND (expires_at IS NULL OR expires_at > now())
  );
END;
$$;


--
-- Name: generate_share_token(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_share_token(p_track_id uuid, p_user_id uuid) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
  token text;
BEGIN
  token := encode(gen_random_bytes(16), 'hex');
  UPDATE public.tracks SET share_token = token WHERE id = p_track_id AND user_id = p_user_id;
  RETURN token;
END;
$$;


--
-- Name: get_ad_for_slot(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_ad_for_slot(p_slot_key text, p_user_id uuid DEFAULT NULL::uuid, p_device_type text DEFAULT 'desktop'::text) RETURNS TABLE(campaign_id uuid, creative_id uuid, campaign_name text, campaign_type text, creative_type text, title text, subtitle text, cta_text text, click_url text, media_url text, media_type text, thumbnail_url text, external_video_url text, internal_type text, internal_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_slot_id uuid;
  v_is_ad_free boolean := false;
  v_ads_enabled boolean := true;
  v_max_impressions_per_hour int := 20;
  v_user_impressions_last_hour int := 0;
  v_current_hour int;
  v_current_dow int;
BEGIN
  -- Глобальный переключатель
  SELECT value::boolean INTO v_ads_enabled
  FROM public.ad_settings
  WHERE key = 'ads_enabled';

  IF NOT COALESCE(v_ads_enabled, true) THEN
    RETURN;
  END IF;

  -- Слот существует и включён?
  SELECT id INTO v_slot_id
  FROM public.ad_slots
  WHERE slot_key = p_slot_key AND COALESCE(is_enabled, is_active, true) = true;

  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;

  -- Проверка ad_free
  IF p_user_id IS NOT NULL THEN
    SELECT CASE
      WHEN p.ad_free_until IS NOT NULL AND p.ad_free_until > now()
      THEN true ELSE false
    END INTO v_is_ad_free
    FROM public.profiles p
    WHERE p.user_id = p_user_id;

    IF v_is_ad_free THEN RETURN; END IF;

    -- Premium-подписка
    IF EXISTS (
      SELECT 1 FROM public.ad_settings WHERE key = 'premium_no_ads' AND value = 'true'
    ) THEN
      IF EXISTS (
        SELECT 1 FROM public.user_subscriptions us
        WHERE us.user_id = p_user_id AND us.status = 'active'
          AND (us.end_date IS NULL OR us.end_date > now())
      ) THEN
        RETURN;
      END IF;
    END IF;
  END IF;

  -- Серверный frequency cap
  SELECT COALESCE(value::int, 20) INTO v_max_impressions_per_hour
  FROM public.ad_settings WHERE key = 'max_ads_per_hour';

  IF p_user_id IS NOT NULL THEN
    SELECT count(*) INTO v_user_impressions_last_hour
    FROM public.ad_impressions ai
    WHERE ai.user_id = p_user_id
      AND COALESCE(ai.viewed_at, ai.created_at) > now() - interval '1 hour';

    IF v_user_impressions_last_hour >= v_max_impressions_per_hour THEN
      RETURN;
    END IF;
  END IF;

  -- Текущее время для таргетинга
  v_current_hour := EXTRACT(HOUR FROM now());
  v_current_dow := EXTRACT(ISODOW FROM now())::int;

  -- Основной запрос
  RETURN QUERY
  SELECT
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    COALESCE(c.campaign_type, 'external') as campaign_type,
    COALESCE(cr.creative_type, cr.type, 'image') as creative_type,
    cr.title,
    COALESCE(cr.subtitle, cr.description) as subtitle,
    cr.cta_text,
    COALESCE(cr.click_url, c.link_url) as click_url,
    COALESCE(cr.media_url, c.image_url) as media_url,
    cr.media_type,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id::text as internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id AND t.target_type IS NULL
  WHERE
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND COALESCE(cs.is_active, true) = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    -- Бюджет: общий
    AND (c.budget_total IS NULL OR COALESCE(c.impressions_count, c.impressions, 0) < c.budget_total)
    -- Бюджет: дневной
    AND (
      c.budget_daily IS NULL
      OR (
        SELECT count(*) FROM public.ad_impressions bi
        WHERE bi.campaign_id = c.id
          AND COALESCE(bi.viewed_at, bi.created_at) >= date_trunc('day', now())
      ) < c.budget_daily
    )
    -- Таргетинг: устройство
    AND (
      t.id IS NULL
      OR (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
    )
    -- Таргетинг: часы показа
    AND (
      t.id IS NULL OR t.show_hours_start IS NULL OR t.show_hours_end IS NULL
      OR (
        CASE
          WHEN t.show_hours_start <= t.show_hours_end THEN
            v_current_hour >= t.show_hours_start AND v_current_hour < t.show_hours_end
          ELSE
            v_current_hour >= t.show_hours_start OR v_current_hour < t.show_hours_end
        END
      )
    )
    -- Таргетинг: дни недели
    AND (
      t.id IS NULL OR t.show_days_of_week IS NULL
      OR v_current_dow = ANY(t.show_days_of_week)
    )
    -- Таргетинг: подписка
    AND (
      t.id IS NULL
      OR (COALESCE(t.target_free_users, true) AND COALESCE(t.target_subscribed_users, true))
      OR (
        t.target_free_users AND NOT EXISTS (
          SELECT 1 FROM public.user_subscriptions us
          WHERE us.user_id = p_user_id AND us.status = 'active'
        )
      )
      OR (
        t.target_subscribed_users AND EXISTS (
          SELECT 1 FROM public.user_subscriptions us
          WHERE us.user_id = p_user_id AND us.status = 'active'
        )
      )
    )
    -- Таргетинг: мин. генераций
    AND (
      t.id IS NULL OR t.min_generations IS NULL OR p_user_id IS NULL
      OR (SELECT count(*) FROM public.tracks tr WHERE tr.user_id = p_user_id) >= t.min_generations
    )
    -- Таргетинг: мин. дней с регистрации
    AND (
      t.id IS NULL OR t.min_days_registered IS NULL OR p_user_id IS NULL
      OR (
        SELECT EXTRACT(DAY FROM now() - p.created_at)
        FROM public.profiles p WHERE p.user_id = p_user_id
      ) >= t.min_days_registered
    )
  ORDER BY
    COALESCE(cs.priority_override, cs.priority, c.priority, 50) DESC,
    random()
  LIMIT 1;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: tracks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    title text NOT NULL,
    description text,
    lyrics text,
    audio_url text,
    cover_url text,
    duration integer DEFAULT 0,
    genre_id uuid,
    model_id uuid,
    vocal_type_id uuid,
    template_id uuid,
    artist_style_id uuid,
    is_public boolean DEFAULT false,
    likes_count integer DEFAULT 0,
    plays_count integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    moderation_status text DEFAULT 'none'::text,
    source_type text DEFAULT 'generated'::text,
    distribution_status text,
    voting_started_at timestamp with time zone,
    voting_ends_at timestamp with time zone,
    voting_likes_count integer DEFAULT 0,
    voting_dislikes_count integer DEFAULT 0,
    voting_result text,
    voting_type text,
    prompt_text text,
    tags text[],
    bpm integer,
    key_signature text,
    suno_id text,
    video_url text,
    is_boosted boolean DEFAULT false,
    boost_expires_at timestamp with time zone,
    downloads_count integer DEFAULT 0,
    shares_count integer DEFAULT 0,
    share_token text,
    copyright_check_status text DEFAULT 'none'::text,
    copyright_check_result jsonb,
    copyright_checked_at timestamp with time zone,
    plagiarism_check_status text DEFAULT 'none'::text,
    plagiarism_check_result jsonb,
    is_original_work boolean DEFAULT true,
    has_samples boolean DEFAULT false,
    samples_licensed boolean,
    performer_name text,
    label_name text,
    wav_url text,
    master_audio_url text,
    certificate_url text,
    contest_winner_badge jsonb,
    moderation_reviewed_by uuid,
    moderation_rejection_reason text,
    moderation_notes text,
    moderation_reviewed_at timestamp with time zone,
    forum_topic_id uuid,
    error_message text,
    "position" integer DEFAULT 0,
    audio_reference_url text,
    blockchain_hash text,
    distribution_approved_at timestamp with time zone,
    distribution_approved_by uuid,
    distribution_platforms jsonb,
    distribution_rejection_reason text,
    distribution_requested_at timestamp with time zone,
    distribution_reviewed_at timestamp with time zone,
    distribution_reviewed_by uuid,
    distribution_submitted_at timestamp with time zone,
    gold_pack_url text,
    has_interpolations boolean DEFAULT false,
    interpolations_licensed boolean DEFAULT false,
    isrc_code text,
    lufs_normalized boolean DEFAULT false,
    lyrics_author text,
    master_uploaded_at timestamp with time zone,
    metadata_cleaned boolean DEFAULT false,
    music_author text,
    processing_completed_at timestamp with time zone,
    processing_progress integer DEFAULT 0,
    processing_stage text,
    processing_started_at timestamp with time zone,
    suno_audio_id text,
    upscale_detected boolean DEFAULT false,
    CONSTRAINT tracks_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: get_boosted_tracks(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_boosted_tracks(p_limit integer DEFAULT 5) RETURNS SETOF public.tracks
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
    SELECT * FROM public.tracks
    WHERE is_boosted = true
    AND (boost_expires_at IS NULL OR boost_expires_at > now())
    AND is_public = true AND status = 'completed'
    ORDER BY boost_expires_at DESC NULLS LAST
    LIMIT p_limit;
END;
$$;


--
-- Name: get_contest_leaderboard(text, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_contest_leaderboard(p_type text DEFAULT 'rating'::text, p_season_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS TABLE(pos bigint, user_id uuid, username text, avatar_url text, rating integer, season_points integer, weekly_points integer, daily_streak integer, total_wins integer, total_top3 integer, league_name text, league_color text, league_tier integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_creator_earnings_profile(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_creator_earnings_profile(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_earnings RECORD;
  v_tier_info RECORD;
  v_privileges JSONB;
  v_recent_shares JSONB;
  v_quality_avg NUMERIC;
BEGIN
  -- Get or create earnings record
  INSERT INTO public.creator_earnings (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_earnings FROM public.creator_earnings WHERE user_id = p_user_id;

  -- Get tier info
  SELECT fus.tier, fus.xp_total, rt.name_ru, rt.marketplace_commission,
         rt.attribution_multiplier, rt.bonus_generations, rt.feed_boost,
         rt.can_sell_premium, rt.can_create_voice_print
  INTO v_tier_info
  FROM public.forum_user_stats fus
  LEFT JOIN public.reputation_tiers rt ON rt.key = fus.tier
  WHERE fus.user_id = p_user_id;

  -- Recent attribution shares
  SELECT COALESCE(jsonb_agg(s ORDER BY s->>'period_start' DESC), '[]'::jsonb)
  INTO v_recent_shares
  FROM (
    SELECT jsonb_build_object(
      'period_start', ap.period_start,
      'engagement_score', ash.engagement_score,
      'earned_amount', ash.earned_amount,
      'pool_share_percent', ash.pool_share_percent
    ) as s
    FROM public.attribution_shares ash
    JOIN public.attribution_pools ap ON ap.id = ash.pool_id
    WHERE ash.user_id = p_user_id
    ORDER BY ap.period_start DESC
    LIMIT 6
  ) sub;

  -- Average quality score
  SELECT COALESCE(AVG(quality_score), 0) INTO v_quality_avg
  FROM public.track_quality_scores
  WHERE user_id = p_user_id AND metrics_collected_at > now() - INTERVAL '30 days';

  RETURN jsonb_build_object(
    'earnings', jsonb_build_object(
      'total_earned', COALESCE(v_earnings.total_earned, 0),
      'total_attribution', COALESCE(v_earnings.total_attribution, 0),
      'total_marketplace', COALESCE(v_earnings.total_marketplace_sales, 0),
      'total_premium', COALESCE(v_earnings.total_premium_content, 0),
      'total_tips', COALESCE(v_earnings.total_tips, 0),
      'total_royalties', COALESCE(v_earnings.total_royalties, 0),
      'current_month', COALESCE(v_earnings.current_month_total, 0),
      'pending_payout', COALESCE(v_earnings.pending_payout, 0)
    ),
    'tier', jsonb_build_object(
      'key', COALESCE(v_tier_info.tier, 'newcomer'),
      'name', COALESCE(v_tier_info.name_ru, '??????????????'),
      'xp', COALESCE(v_tier_info.xp_total, 0),
      'commission', COALESCE(v_tier_info.marketplace_commission, 0.15),
      'attribution_multiplier', COALESCE(v_tier_info.attribution_multiplier, 0),
      'bonus_generations', COALESCE(v_tier_info.bonus_generations, 0),
      'feed_boost', COALESCE(v_tier_info.feed_boost, 1.0),
      'can_sell_premium', COALESCE(v_tier_info.can_sell_premium, false),
      'can_create_voice_print', COALESCE(v_tier_info.can_create_voice_print, false)
    ),
    'quality_avg', v_quality_avg,
    'recent_attribution', v_recent_shares
  );
END;
$$;


--
-- Name: get_economy_health(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_economy_health() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_total_balance BIGINT;
  v_total_users INTEGER;
  v_active_creators INTEGER;
  v_paying_users INTEGER;
  v_avg_quality NUMERIC;
  v_tracks_today INTEGER;
  v_generations_today INTEGER;
  v_top_earners JSONB;
  v_tier_distribution JSONB;
  v_recent_pool RECORD;
BEGIN
  -- Total AIPCI in circulation
  SELECT COALESCE(SUM(balance), 0) INTO v_total_balance FROM public.profiles;

  -- User counts
  SELECT COUNT(*) INTO v_total_users FROM public.profiles;

  SELECT COUNT(DISTINCT user_id) INTO v_active_creators
  FROM public.tracks
  WHERE created_at > now() - INTERVAL '30 days' AND status = 'completed';

  SELECT COUNT(DISTINCT user_id) INTO v_paying_users
  FROM public.user_subscriptions
  WHERE status = 'active' AND current_period_end > now();

  -- Average track quality
  SELECT COALESCE(AVG(quality_score), 0) INTO v_avg_quality
  FROM public.track_quality_scores
  WHERE metrics_collected_at > now() - INTERVAL '30 days';

  -- Today's tracks
  SELECT COUNT(*) INTO v_tracks_today
  FROM public.tracks
  WHERE created_at > CURRENT_DATE AND status = 'completed';

  -- Tier distribution
  SELECT COALESCE(jsonb_agg(jsonb_build_object('tier', tier, 'count', cnt)), '[]'::jsonb)
  INTO v_tier_distribution
  FROM (
    SELECT COALESCE(tier, 'newcomer') as tier, COUNT(*) as cnt
    FROM public.forum_user_stats
    GROUP BY tier
    ORDER BY cnt DESC
  ) t;

  -- Top earners
  SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_top_earners
  FROM (
    SELECT ce.user_id, ce.total_earned, ce.current_month_total,
           p.username, p.avatar_url,
           fus.tier
    FROM public.creator_earnings ce
    JOIN public.profiles p ON p.user_id = ce.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = ce.user_id
    ORDER BY ce.current_month_total DESC
    LIMIT 10
  ) e;

  -- Latest attribution pool
  SELECT * INTO v_recent_pool
  FROM public.attribution_pools
  ORDER BY period_start DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'currency', jsonb_build_object(
      'total_in_circulation', v_total_balance,
      'avg_per_user', CASE WHEN v_total_users > 0 THEN v_total_balance / v_total_users ELSE 0 END
    ),
    'users', jsonb_build_object(
      'total', v_total_users,
      'active_creators', v_active_creators,
      'paying', v_paying_users,
      'tier_distribution', v_tier_distribution
    ),
    'content', jsonb_build_object(
      'tracks_today', v_tracks_today,
      'avg_quality', v_avg_quality
    ),
    'attribution_pool', CASE WHEN v_recent_pool.id IS NOT NULL THEN jsonb_build_object(
      'id', v_recent_pool.id,
      'period', v_recent_pool.period_start || ' ??? ' || v_recent_pool.period_end,
      'total_pool', v_recent_pool.total_pool,
      'total_distributed', v_recent_pool.total_distributed,
      'eligible_creators', v_recent_pool.total_eligible_creators,
      'status', v_recent_pool.status
    ) ELSE '{}'::jsonb END,
    'top_earners', v_top_earners
  );
END;
$$;


--
-- Name: get_feed_tracks_with_profiles(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_feed_tracks_with_profiles(p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, title text, description text, audio_url text, cover_url text, duration integer, user_id uuid, genre_id uuid, likes_count integer, plays_count integer, status text, created_at timestamp with time zone, username text, avatar_url text, display_name text)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
    SELECT t.id, t.title, t.description, t.audio_url, t.cover_url,
           t.duration, t.user_id, t.genre_id, t.likes_count,
           t.plays_count, t.status, t.created_at,
           p.username, p.avatar_url, p.display_name
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    WHERE t.is_public = true AND t.status = 'completed'
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- Name: get_feed_tracks_with_profiles(uuid, text, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_feed_tracks_with_profiles(p_user_id uuid DEFAULT NULL::uuid, p_tab text DEFAULT 'new'::text, p_genre_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, title text, description text, audio_url text, cover_url text, duration integer, user_id uuid, genre_id uuid, is_public boolean, likes_count integer, plays_count integer, status text, created_at timestamp with time zone, profile_username text, profile_avatar_url text, genre_name_ru text)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
    SELECT t.id, t.title, t.description, t.audio_url, t.cover_url,
           t.duration, t.user_id, t.genre_id, t.is_public,
           t.likes_count, t.plays_count, t.status, t.created_at,
           p.username AS profile_username,
           p.avatar_url AS profile_avatar_url,
           g.name_ru AS genre_name_ru
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    WHERE t.is_public = true
      AND t.status = 'completed'
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks ub
        WHERE ub.user_id = t.user_id
          AND (ub.expires_at IS NULL OR ub.expires_at > now())
      )
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    ORDER BY
      CASE WHEN p_tab = 'trending' THEN t.plays_count END DESC NULLS LAST,
      CASE WHEN p_tab = 'new' THEN t.created_at END DESC,
      CASE WHEN p_tab = 'following' THEN t.created_at END DESC,
      t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- Name: get_last_messages(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_last_messages(p_conversation_ids uuid[]) RETURNS TABLE(conversation_id uuid, content text, created_at timestamp with time zone, sender_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT DISTINCT ON (m.conversation_id)
    m.conversation_id,
    m.content,
    m.created_at,
    m.sender_id
  FROM messages m
  WHERE m.conversation_id = ANY(p_conversation_ids)
    AND m.deleted_at IS NULL
  ORDER BY m.conversation_id, m.created_at DESC;
$$;


--
-- Name: get_or_create_referral_code(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_referral_code(p_user_id uuid) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
  existing_code text;
  new_code text;
BEGIN
  SELECT code INTO existing_code FROM public.referral_codes WHERE user_id = p_user_id LIMIT 1;
  IF existing_code IS NOT NULL THEN RETURN existing_code; END IF;

  SELECT p.referral_code INTO existing_code FROM public.profiles p WHERE p.user_id = p_user_id;
  IF existing_code IS NOT NULL AND existing_code != '' THEN RETURN existing_code; END IF;

  new_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
  INSERT INTO public.referral_codes (user_id, code) VALUES (p_user_id, new_code) ON CONFLICT DO NOTHING;
  UPDATE public.profiles SET referral_code = new_code WHERE user_id = p_user_id AND (referral_code IS NULL OR referral_code = '');
  RETURN new_code;
END;
$$;


--
-- Name: get_qa_dashboard_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_qa_dashboard_stats() RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total', COUNT(*),
    'new', COUNT(*) FILTER (WHERE status = 'new'),
    'confirmed', COUNT(*) FILTER (WHERE status = 'confirmed'),
    'triaged', COUNT(*) FILTER (WHERE status = 'triaged'),
    'in_progress', COUNT(*) FILTER (WHERE status = 'in_progress'),
    'fixed', COUNT(*) FILTER (WHERE status = 'fixed'),
    'closed', COUNT(*) FILTER (WHERE status IN ('closed', 'wont_fix', 'duplicate')),
    'critical', COUNT(*) FILTER (WHERE severity IN ('critical', 'blocker')),
    'verified', COUNT(*) FILTER (WHERE is_verified = true),
    'avg_resolution_hours', ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))/3600) FILTER (WHERE resolved_at IS NOT NULL)::NUMERIC, 1),
    'today', COUNT(*) FILTER (WHERE created_at::DATE = CURRENT_DATE),
    'this_week', COUNT(*) FILTER (WHERE created_at >= date_trunc('week', CURRENT_DATE))
  ) INTO v_result
  FROM public.qa_tickets;

  RETURN v_result;
END;
$$;


--
-- Name: get_qa_leaderboard(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_qa_leaderboard(p_limit integer DEFAULT 20) RETURNS TABLE(user_id uuid, username text, avatar_url text, tier text, reports_confirmed integer, reports_total integer, accuracy_rate numeric, xp_earned integer, credits_earned integer, streak_days integer)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.user_id,
    p.username,
    p.avatar_url,
    s.tier,
    s.reports_confirmed,
    s.reports_total,
    s.accuracy_rate,
    s.xp_earned,
    s.credits_earned,
    s.streak_days
  FROM public.qa_tester_stats s
  LEFT JOIN public.profiles p ON p.user_id = s.user_id
  WHERE s.reports_total > 0
  ORDER BY s.reports_confirmed DESC, s.accuracy_rate DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_radio_smart_queue(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_smart_queue(p_user_id uuid DEFAULT NULL::uuid, p_genre_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS TABLE(track_id uuid, title text, audio_url text, cover_url text, duration integer, author_id uuid, author_username text, author_avatar text, author_tier text, author_xp integer, genre_name text, chance_score numeric, quality_component numeric, xp_component numeric, freshness_component numeric, discovery_component numeric, source text, is_boosted boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
DECLARE
  v_cfg JSONB;
  v_w_quality NUMERIC;
  v_w_xp NUMERIC;
  v_w_stake NUMERIC;
  v_w_freshness NUMERIC;
  v_w_discovery NUMERIC;
  v_discovery_days INTEGER;
  v_discovery_mult NUMERIC;
  v_min_quality NUMERIC;
  v_min_duration INTEGER;
  v_max_author_pct NUMERIC;
BEGIN
  -- Load config
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'smart_stream';

  v_w_quality     := COALESCE((v_cfg->>'W_quality')::numeric, 0.35);
  v_w_xp          := COALESCE((v_cfg->>'W_xp')::numeric, 0.25);
  v_w_stake       := COALESCE((v_cfg->>'W_stake')::numeric, 0.20);
  v_w_freshness   := COALESCE((v_cfg->>'W_freshness')::numeric, 0.15);
  v_w_discovery   := COALESCE((v_cfg->>'W_discovery')::numeric, 0.05);
  v_discovery_days := COALESCE((v_cfg->>'discovery_boost_days')::int, 14);
  v_discovery_mult := COALESCE((v_cfg->>'discovery_boost_multiplier')::numeric, 2.5);
  v_min_quality   := COALESCE((v_cfg->>'min_quality_score')::numeric, 2.0);
  v_min_duration  := COALESCE((v_cfg->>'min_duration_sec')::int, 30);
  v_max_author_pct := COALESCE((v_cfg->>'max_author_share_percent')::numeric, 15);

  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS track_id,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, 0)::integer AS author_xp,
      g.name_ru AS genre_name,
      -- Quality component (0-100): track quality + engagement
      LEAST(
        COALESCE(tqs.quality_score, 5) * 10 +
        LEAST(COALESCE(t.likes_count, 0), 50) * 0.5 +
        LEAST(COALESCE(t.plays_count, 0), 200) * 0.1,
        100
      )::numeric AS q_score,
      -- XP component (0-100): author reputation normalized
      LEAST(COALESCE(fus.xp_total, 0)::numeric / 50, 100)::numeric AS xp_score,
      -- Freshness component (0-100): newer = higher
      GREATEST(
        100 - EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400 * 3.33,
        0
      )::numeric AS fresh_score,
      -- Discovery component (0-100): boost for new authors
      (CASE
        WHEN COALESCE(fus.xp_total, 0) < 100
          AND t.created_at > now() - (v_discovery_days || ' days')::interval
        THEN 100 * v_discovery_mult
        ELSE 0
      END)::numeric AS disc_score,
      -- Stake component: from active promotions
      COALESCE((
        SELECT SUM(tp.amount)
        FROM public.track_promotions tp
        WHERE tp.track_id = t.id AND tp.status = 'active' AND tp.ends_at > now()
      ), 0) AS stake_score,
      -- Is boosted?
      EXISTS (
        SELECT 1 FROM public.track_promotions tp
        WHERE tp.track_id = t.id AND tp.status = 'active' AND tp.ends_at > now()
      ) AS is_boosted,
      t.genre_id
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
    WHERE t.is_public = true
      AND t.status = 'completed'
      AND t.audio_url IS NOT NULL
      AND COALESCE(t.duration, 0) >= v_min_duration
      -- Exclude blocked users
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks ub
        WHERE ub.user_id = t.user_id
          AND (ub.expires_at IS NULL OR ub.expires_at > now())
      )
      -- Genre filter
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
      -- Quality gate
      AND COALESCE(tqs.quality_score, 5) >= v_min_quality
  )
  SELECT
    s.track_id, s.title, s.audio_url, s.cover_url, s.duration,
    s.author_id, s.author_username, s.author_avatar, s.author_tier,
    s.author_xp, s.genre_name,
    -- Final chance score (weighted sum)
    (s.q_score * v_w_quality +
     s.xp_score * v_w_xp +
     LEAST(s.stake_score, 100) * v_w_stake +
     s.fresh_score * v_w_freshness +
     s.disc_score * v_w_discovery
    )::numeric + (random() * 10)::numeric AS chance_score, -- small randomness
    s.q_score AS quality_component,
    s.xp_score AS xp_component,
    s.fresh_score AS freshness_component,
    s.disc_score AS discovery_component,
    CASE WHEN s.is_boosted THEN 'boost' ELSE 'algorithm' END AS source,
    s.is_boosted
  FROM scored s
  ORDER BY
    -- Final score with randomization
    (s.q_score * v_w_quality +
     s.xp_score * v_w_xp +
     LEAST(s.stake_score, 100) * v_w_stake +
     s.fresh_score * v_w_freshness +
     s.disc_score * v_w_discovery
    ) + (random() * 10) DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_radio_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_stats() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_listens_today', (SELECT COUNT(*) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'unique_listeners_today', (SELECT COUNT(DISTINCT user_id) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'xp_awarded_today', (SELECT COALESCE(SUM(xp_earned), 0) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'active_predictions', (SELECT COUNT(*) FROM radio_predictions WHERE status = 'pending'),
    'predictions_pool', (SELECT COALESCE(SUM(bet_amount), 0) FROM radio_predictions WHERE status = 'pending'),
    'active_slots', (SELECT COUNT(*) FROM radio_slots WHERE status IN ('open', 'bidding')),
    'total_auction_revenue', (SELECT COALESCE(SUM(winning_bid), 0) FROM radio_slots WHERE status = 'completed'),
    'tracks_in_queue', (SELECT COUNT(*) FROM radio_queue WHERE NOT is_played),
    'top_track_today', (
      SELECT jsonb_build_object('track_id', track_id, 'listens', COUNT(*))
      FROM radio_listens WHERE created_at >= CURRENT_DATE
      GROUP BY track_id ORDER BY COUNT(*) DESC LIMIT 1
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;


--
-- Name: get_recent_voters(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_recent_voters(p_track_id uuid, p_limit integer DEFAULT 10) RETURNS TABLE(user_id uuid, username text, avatar_url text, vote_type text, voted_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    tv.user_id,
    p.username,
    p.avatar_url,
    tv.vote_type,
    tv.created_at AS voted_at
  FROM public.track_votes tv
  LEFT JOIN public.profiles p ON p.user_id = tv.user_id
  WHERE tv.track_id = p_track_id
  ORDER BY tv.created_at DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_reputation_leaderboard(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reputation_leaderboard(p_type text DEFAULT 'xp'::text, p_limit integer DEFAULT 50) RETURNS TABLE(pos bigint, user_id uuid, username text, avatar_url text, xp_total integer, reputation_score integer, tier text, tier_name text, tier_icon text, tier_color text, streak_days integer, achievements_count bigint)
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


--
-- Name: get_reputation_profile(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reputation_profile(p_user_id uuid) RETURNS jsonb
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


--
-- Name: get_smart_feed(uuid, text, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_smart_feed(p_user_id uuid DEFAULT NULL::uuid, p_stream text DEFAULT 'main'::text, p_genre_id uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20) RETURNS TABLE(id uuid, title text, description text, audio_url text, cover_url text, duration integer, user_id uuid, genre_id uuid, is_public boolean, likes_count integer, plays_count integer, comments_count integer, shares_count integer, saves_count integer, status text, created_at timestamp with time zone, profile_username text, profile_avatar_url text, profile_display_name text, author_tier text, author_tier_icon text, author_tier_color text, author_verified boolean, genre_name_ru text, feed_score numeric, feed_velocity numeric, is_boosted boolean, boost_expires_at timestamp with time zone, quality_score numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
DECLARE
  v_config JSONB;
  v_decay JSONB;
  v_qg JSONB;
  v_following_ids UUID[];
  v_half_life NUMERIC;
BEGIN
  -- Load config
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';

  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  -- Get following list for 'following' stream
  IF p_stream = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM public.follows
    WHERE follower_id = p_user_id;

    IF v_following_ids IS NULL OR array_length(v_following_ids, 1) IS NULL THEN
      RETURN; -- empty result for users who follow nobody
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    t.id, t.title, t.description, t.audio_url, t.cover_url,
    t.duration, t.user_id, t.genre_id, t.is_public,
    t.likes_count, t.plays_count,
    (SELECT COUNT(*)::integer FROM public.track_comments tc WHERE tc.track_id = t.id) AS comments_count,
    COALESCE(t.shares_count, 0)::integer AS shares_count,
    (SELECT COUNT(*)::integer FROM public.playlist_tracks pt WHERE pt.track_id = t.id) AS saves_count,
    t.status, t.created_at,
    -- Author profile
    p.username AS profile_username,
    p.avatar_url AS profile_avatar_url,
    p.display_name AS profile_display_name,
    -- Author tier
    COALESCE(fus.tier, 'newcomer') AS author_tier,
    rt.icon AS author_tier_icon,
    rt.color AS author_tier_color,
    COALESCE(p.is_verified, false) AS author_verified,
    -- Genre
    g.name_ru AS genre_name_ru,
    -- Feed scoring
    COALESCE(fs.final_score, 0) AS feed_score,
    COALESCE(fs.velocity_24h, 0) AS feed_velocity,
    -- Boost info
    (bt.id IS NOT NULL AND bt.expires_at > now()) AS is_boosted,
    bt.expires_at AS boost_expires_at,
    -- Quality
    COALESCE(tqs.quality_score, 0) AS quality_score
  FROM public.tracks t
  LEFT JOIN public.profiles p ON p.user_id = t.user_id
  LEFT JOIN public.genres g ON g.id = t.genre_id
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
  LEFT JOIN public.reputation_tiers rt ON rt.key = COALESCE(fus.tier, 'newcomer')
  LEFT JOIN public.track_feed_scores fs ON fs.track_id = t.id
  LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
  LEFT JOIN LATERAL (
    SELECT bt2.id, bt2.ends_at AS expires_at
    FROM public.track_promotions bt2
    WHERE bt2.track_id = t.id AND bt2.status = 'active' AND bt2.ends_at > now()
    LIMIT 1
  ) bt ON true
  WHERE t.is_public = true
    AND t.status = 'completed'
    -- Exclude blocked users
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE ub.user_id = t.user_id
        AND (ub.expires_at IS NULL OR ub.expires_at > now())
    )
    -- Genre filter
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    -- Stream filters
    AND (
      CASE p_stream
        WHEN 'following' THEN t.user_id = ANY(v_following_ids)
        WHEN 'trending' THEN
          COALESCE(t.plays_count, 0) >= COALESCE((v_qg->>'min_plays_for_trending')::int, 5)
          AND COALESCE(tqs.quality_score, 5) >= COALESCE((v_qg->>'min_score_for_trending')::numeric, 3.0)
        WHEN 'deep' THEN
          COALESCE(t.plays_count, 0) < 20
          AND t.created_at > now() - interval '14 days'
        ELSE true -- 'main' and 'fresh' show all
      END
    )
    -- Duration gate
    AND COALESCE(t.duration, 0) >= COALESCE((v_qg->>'min_duration_sec')::int, 30)
    -- Not spam
    AND COALESCE(fs.is_spam, false) = false
  ORDER BY
    CASE p_stream
      -- Main: smart score with time decay
      WHEN 'main' THEN
        COALESCE(fs.final_score, 0) *
        POWER(0.5, EXTRACT(EPOCH FROM (now() - t.created_at)) / 3600 / v_half_life)
        + CASE WHEN bt.id IS NOT NULL THEN 100 ELSE 0 END
      -- Trending: velocity (speed of engagement growth)
      WHEN 'trending' THEN COALESCE(fs.velocity_24h, 0)
      -- Fresh: newest first
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM t.created_at)
      -- Following: newest first
      WHEN 'following' THEN EXTRACT(EPOCH FROM t.created_at)
      -- Deep: random-ish underrated gems
      WHEN 'deep' THEN random() * 100 + COALESCE(tqs.quality_score, 5) * 10
      ELSE EXTRACT(EPOCH FROM t.created_at)
    END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- Name: get_track_by_share_token(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_track_by_share_token(p_token text) RETURNS SETOF public.tracks
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY SELECT * FROM public.tracks WHERE share_token = p_token LIMIT 1;
END;
$$;


--
-- Name: get_track_prompt_if_accessible(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
  track_record record;
BEGIN
  SELECT prompt_text, user_id, is_public INTO track_record FROM public.tracks WHERE id = p_track_id;
  IF track_record.user_id = p_user_id OR track_record.is_public THEN
    RETURN track_record.prompt_text;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: get_track_prompt_info(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_track_prompt_info(p_track_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'has_prompt', (t.prompt_text IS NOT NULL AND t.prompt_text != ''),
    'is_public', t.is_public,
    'user_id', t.user_id
  ) INTO result
  FROM public.tracks t WHERE t.id = p_track_id;
  RETURN COALESCE(result, '{}'::jsonb);
END;
$$;


--
-- Name: get_unread_counts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_unread_counts(p_user_id uuid) RETURNS TABLE(conversation_id uuid, unread_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT 
    cp.conversation_id,
    COUNT(m.id) AS unread_count
  FROM conversation_participants cp
  LEFT JOIN messages m ON m.conversation_id = cp.conversation_id
    AND m.sender_id != p_user_id
    AND m.created_at > COALESCE(cp.last_read_at, '1970-01-01'::timestamptz)
    AND m.deleted_at IS NULL
  WHERE cp.user_id = p_user_id
  GROUP BY cp.conversation_id;
$$;


--
-- Name: get_user_block_info(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_block_info(p_user_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  result jsonb;
BEGIN
  IF p_user_id IS NULL THEN RETURN '{"is_blocked": false}'::jsonb; END IF;
  
  SELECT jsonb_build_object(
    'is_blocked', true,
    'reason', b.reason,
    'expires_at', b.expires_at,
    'created_at', b.created_at
  ) INTO result
  FROM public.user_blocks b
  WHERE b.user_id = p_user_id
  AND (b.expires_at IS NULL OR b.expires_at > now())
  ORDER BY b.created_at DESC
  LIMIT 1;
  
  RETURN COALESCE(result, '{"is_blocked": false}'::jsonb);
END;
$$;


--
-- Name: get_user_contest_rating(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_contest_rating(p_user_id uuid) RETURNS TABLE(rating integer, league_name text, league_color text, league_tier integer, league_multiplier numeric, season_points integer, weekly_points integer, daily_streak integer, best_streak integer, total_contests integer, total_wins integer, total_top3 integer, total_votes_received integer, global_rank bigint, achievements_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_user_emails(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_emails(p_user_ids uuid[] DEFAULT NULL::uuid[]) RETURNS TABLE(user_id uuid, email text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  IF p_user_ids IS NULL THEN
    RETURN QUERY SELECT u.id, u.email FROM auth.users u;
  ELSE
    RETURN QUERY SELECT u.id, u.email FROM auth.users u WHERE u.id = ANY(p_user_ids);
  END IF;
END;
$$;


--
-- Name: get_user_role(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_role(_user_id uuid) RETURNS public.app_role
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT role FROM public.user_roles WHERE user_id = _user_id ORDER BY 
      CASE role 
        WHEN 'super_admin' THEN 1 
        WHEN 'admin' THEN 2 
        WHEN 'moderator' THEN 3 
        ELSE 4 
      END 
      LIMIT 1),
    'user'::app_role
  )
$$;


--
-- Name: get_user_stats(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_stats(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'tracks_count', (SELECT COUNT(*) FROM public.tracks WHERE user_id = p_user_id),
    'total_likes', COALESCE((SELECT SUM(likes_count) FROM public.tracks WHERE user_id = p_user_id), 0),
    'followers_count', (SELECT COUNT(*) FROM public.follows WHERE following_id = p_user_id),
    'following_count', (SELECT COUNT(*) FROM public.follows WHERE follower_id = p_user_id)
  ) INTO result;
  RETURN result;
END;
$$;


--
-- Name: get_user_vote_weight(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_vote_weight(p_user_id uuid) RETURNS numeric
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


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    NEW.email,
    100,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
    display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
    email = COALESCE(EXCLUDED.email, public.profiles.email);
  RETURN NEW;
END;
$$;


--
-- Name: has_permission(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_permission(_user_id uuid, _category_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT 
    is_admin(_user_id)
    OR
    EXISTS (
      SELECT 1 
      FROM public.moderator_permissions mp
      JOIN public.permission_categories pc ON pc.id = mp.category_id
      WHERE mp.user_id = _user_id AND pc.key = _category_key AND pc.is_active = true
    )
$$;


--
-- Name: has_purchased_item(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_purchased_item(p_item_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM public.item_purchases WHERE item_id = p_item_id AND buyer_id = p_user_id AND status = 'completed');
END;
$$;


--
-- Name: has_purchased_prompt(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_purchased_prompt(p_prompt_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM public.prompt_purchases WHERE prompt_id = p_prompt_id AND buyer_id = p_user_id AND status = 'completed');
END;
$$;


--
-- Name: has_role(uuid, public.app_role); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_role(_user_id uuid, _role public.app_role) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
$$;


--
-- Name: hide_contest_comment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hide_contest_comment(p_comment_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.contest_entry_comments SET is_hidden = true WHERE id = p_comment_id;
END;
$$;


--
-- Name: hide_track_comment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hide_track_comment(p_comment_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.track_comments SET is_hidden = true WHERE id = p_comment_id;
END;
$$;


--
-- Name: increment_prompt_downloads(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_prompt_downloads(p_prompt_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;
END;
$$;


--
-- Name: is_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin(_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role IN ('admin', 'super_admin')
  )
$$;


--
-- Name: is_maintenance_whitelisted(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_maintenance_whitelisted(_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.maintenance_whitelist
    WHERE user_id = _user_id
  )
$$;


--
-- Name: is_participant_in_conversation(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_participant_in_conversation(p_user_id uuid, p_conversation_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM conversation_participants
    WHERE user_id = p_user_id AND conversation_id = p_conversation_id
  )
$$;


--
-- Name: is_super_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_super_admin(_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role = 'super_admin'
  )
$$;


--
-- Name: is_user_blocked(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_user_blocked(_user_id uuid DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.blocked_users
    WHERE user_id = COALESCE(_user_id, auth.uid())
      AND (blocked_until IS NULL OR blocked_until > now())
  );
EXCEPTION WHEN undefined_table THEN
  RETURN false;
END;
$$;


--
-- Name: notify_table_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_table_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  payload jsonb;
  record_data jsonb;
  op text;
BEGIN
  op := TG_OP;

  IF op = 'DELETE' THEN
    record_data := to_jsonb(OLD);
  ELSE
    record_data := to_jsonb(NEW);
  END IF;

  -- Сначала пробуем отправить полные данные
  payload := jsonb_build_object(
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'type', op,
    'record', record_data,
    'old_record', CASE WHEN op = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END
  );

  -- CRITICAL FIX: используем octet_length (байты) вместо length (символы)
  -- pg_notify ограничен 8000 байтами, а не символами
  IF octet_length(payload::text) > 7500 THEN
    -- Для больших записей (треки с lyrics/description) отправляем только id и ключевые поля
    payload := jsonb_build_object(
      'table', TG_TABLE_NAME,
      'schema', TG_TABLE_SCHEMA,
      'type', op,
      'record', jsonb_build_object(
        'id', CASE WHEN op = 'DELETE' THEN OLD.id ELSE NEW.id END
      ),
      'old_record', NULL
    );
  END IF;

  PERFORM pg_notify('table_changes', payload::text);

  IF op = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: pin_comment(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pin_comment(p_comment_id uuid, p_pinned boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.track_comments SET is_pinned = p_pinned WHERE id = p_comment_id;
END;
$$;


--
-- Name: prevent_self_vote(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_self_vote() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: process_beat_purchase(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_beat_purchase(p_beat_id uuid, p_buyer_id uuid, p_license_type text DEFAULT 'basic'::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  beat record;
  purchase_id uuid;
BEGIN
  SELECT * INTO beat FROM public.store_beats WHERE id = p_beat_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Beat not found or inactive'; END IF;

  UPDATE public.profiles SET balance = balance - beat.price WHERE user_id = p_buyer_id AND balance >= beat.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.beat_purchases (buyer_id, beat_id, seller_id, price, license_type, status)
  VALUES (p_buyer_id, p_beat_id, beat.seller_id, beat.price, p_license_type, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.store_beats SET sales_count = sales_count + 1 WHERE id = p_beat_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount, status)
  VALUES (beat.seller_id, beat.price, 'beat_sale', purchase_id, beat.price * 0.1, beat.price * 0.9, 'pending');

  RETURN purchase_id;
END;
$$;


--
-- Name: process_contest_lifecycle(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_contest_lifecycle() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_processed integer := 0;
  v_contest record;
BEGIN
  FOR v_contest IN
    SELECT id FROM public.contests
    WHERE status = 'active' AND end_date <= now()
  LOOP
    UPDATE public.contests SET status = 'voting' WHERE id = v_contest.id;
    v_processed := v_processed + 1;
  END LOOP;

  FOR v_contest IN
    SELECT id FROM public.contests
    WHERE status = 'voting'
      AND voting_end_date <= now()
      AND COALESCE(auto_finalize, true) = true
  LOOP
    PERFORM public.finalize_contest(v_contest.id);
    v_processed := v_processed + 1;
  END LOOP;

  UPDATE public.contest_seasons SET status = 'active'
  WHERE status = 'upcoming' AND start_date <= now();
  UPDATE public.contest_seasons SET status = 'completed'
  WHERE status = 'active' AND end_date <= now();

  RETURN v_processed;
END;
$$;


--
-- Name: process_prompt_purchase(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_prompt_purchase(p_prompt_id uuid, p_buyer_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  prompt record;
  purchase_id uuid;
BEGIN
  SELECT * INTO prompt FROM public.user_prompts WHERE id = p_prompt_id AND is_public = true AND price > 0;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prompt not found'; END IF;

  UPDATE public.profiles SET balance = balance - prompt.price WHERE user_id = p_buyer_id AND balance >= prompt.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.prompt_purchases (buyer_id, prompt_id, seller_id, price, status)
  VALUES (p_buyer_id, p_prompt_id, prompt.user_id, prompt.price, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;
  RETURN purchase_id;
END;
$$;


--
-- Name: process_store_item_purchase(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_store_item_purchase(p_item_id uuid, p_buyer_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  item record;
  purchase_id uuid;
BEGIN
  SELECT * INTO item FROM public.store_items WHERE id = p_item_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;

  UPDATE public.profiles SET balance = balance - item.price WHERE user_id = p_buyer_id AND balance >= item.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.item_purchases (item_id, buyer_id, seller_id, price, status)
  VALUES (p_item_id, p_buyer_id, item.user_id, item.price, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_item_id;
  RETURN purchase_id;
END;
$$;


--
-- Name: protect_super_admin_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_super_admin_role() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.role::text = 'super_admin' THEN
    RAISE EXCEPTION 'Cannot delete super_admin role. Protected.';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.role::text = 'super_admin' AND NEW.role::text != 'super_admin' THEN
    RAISE EXCEPTION 'Cannot demote super_admin. Protected.';
  END IF;
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role::text = 'super_admin' THEN
    IF NEW.user_id != 'a0000000-0000-0000-0000-000000000001' THEN
      RAISE EXCEPTION 'Cannot assign super_admin to other users. Reserved.';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_superadmin_auth_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_superadmin_auth_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.is_super_admin = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Суперадмин защищён на уровне базы данных. Удаление невозможно.';
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: protect_superadmin_auth_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_superadmin_auth_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.is_super_admin = true THEN
    -- Нельзя менять email, пароль, is_super_admin
    IF NEW.email != OLD.email THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить email суперадмина.';
    END IF;
    IF NEW.encrypted_password != OLD.encrypted_password THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить пароль суперадмина.';
    END IF;
    IF NEW.is_super_admin != OLD.is_super_admin THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя снять статус суперадмина.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_superadmin_profile_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_superadmin_profile_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.is_protected = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Профиль суперадмина защищён. Удаление невозможно.';
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: protect_superadmin_profile_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_superadmin_profile_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.is_protected = true THEN
    IF NEW.is_protected != OLD.is_protected THEN
      RAISE EXCEPTION '??????????????????: ???????????? ?????????? ???????????? ??????????????????????.';
    END IF;
    IF NEW.is_super_admin != OLD.is_super_admin THEN
      RAISE EXCEPTION '??????????????????: ???????????? ???????????????? ???????????? ??????????????????????.';
    END IF;
    -- FIXED: 'superadmin' ??? 'super_admin'
    IF NEW.role != 'super_admin' AND OLD.role = 'super_admin' THEN
      RAISE EXCEPTION '??????????????????: ???????????? ???????????????? ???????? ??????????????????????.';
    END IF;
    IF NEW.user_id != OLD.user_id THEN
      RAISE EXCEPTION '??????????????????: ???????????? ???????????????? user_id ??????????????????????.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_superadmin_role_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_superadmin_role_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  _is_protected boolean;
BEGIN
  SELECT is_protected INTO _is_protected FROM public.profiles WHERE user_id = OLD.user_id;
  IF _is_protected = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя удалить роль суперадмина.';
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: purchase_ad_free(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purchase_ad_free(p_user_id uuid, p_days integer DEFAULT 30, p_cost integer DEFAULT 99) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  current_balance integer;
BEGIN
  SELECT balance INTO current_balance FROM public.profiles WHERE user_id = p_user_id;
  IF current_balance IS NULL OR current_balance < p_cost THEN RETURN false; END IF;

  UPDATE public.profiles
  SET balance = balance - p_cost,
      ad_free_until = GREATEST(COALESCE(ad_free_until, now()), now()) + (p_days || ' days')::interval
  WHERE user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description)
  VALUES (p_user_id, -p_cost, 'ad_free', 'Покупка отключения рекламы');

  RETURN true;
END;
$$;


--
-- Name: purchase_track_boost(uuid, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purchase_track_boost(p_track_id uuid, p_user_id uuid, p_duration_hours integer DEFAULT 24, p_cost integer DEFAULT 50) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  current_balance integer;
BEGIN
  SELECT balance INTO current_balance FROM public.profiles WHERE user_id = p_user_id;
  IF current_balance IS NULL OR current_balance < p_cost THEN RETURN false; END IF;

  UPDATE public.profiles SET balance = balance - p_cost WHERE user_id = p_user_id;
  UPDATE public.tracks
  SET is_boosted = true, boost_expires_at = now() + (p_duration_hours || ' hours')::interval
  WHERE id = p_track_id AND user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id)
  VALUES (p_user_id, -p_cost, 'boost', 'Boost трека', 'track', p_track_id);

  RETURN true;
END;
$$;


--
-- Name: qa_generate_ticket_number(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.qa_generate_ticket_number() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  next_num INTEGER;
BEGIN
  SELECT COALESCE(MAX(CAST(SUBSTRING(ticket_number FROM 4) AS INTEGER)), 0) + 1
    INTO next_num
    FROM public.qa_tickets
    WHERE ticket_number LIKE 'QA-%';
  NEW.ticket_number := 'QA-' || LPAD(next_num::TEXT, 6, '0');
  RETURN NEW;
END;
$$;


--
-- Name: qa_recalculate_priority(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.qa_recalculate_priority(p_ticket_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_severity_weight NUMERIC;
  v_upvote_score NUMERIC;
  v_age_bonus NUMERIC;
  v_ticket RECORD;
BEGIN
  SELECT * INTO v_ticket FROM public.qa_tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_severity_weight := CASE v_ticket.severity
    WHEN 'cosmetic' THEN 1 WHEN 'minor' THEN 2
    WHEN 'major' THEN 5 WHEN 'critical' THEN 10
    WHEN 'blocker' THEN 20 ELSE 2 END;

  v_upvote_score := COALESCE(
    (SELECT SUM(voter_weight) FROM public.qa_votes WHERE ticket_id = p_ticket_id), 0
  );

  v_age_bonus := LEAST(5, EXTRACT(EPOCH FROM (now() - v_ticket.created_at)) / 86400.0);

  UPDATE public.qa_tickets
    SET priority_score = ROUND((v_severity_weight * 10 + v_upvote_score * 5 + v_age_bonus)::NUMERIC, 2)
    WHERE id = p_ticket_id;
END;
$$;


--
-- Name: qa_update_tester_tier(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.qa_update_tester_tier(p_user_id uuid) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_stats RECORD;
  v_new_tier TEXT;
  v_accuracy NUMERIC;
BEGIN
  SELECT * INTO v_stats FROM public.qa_tester_stats WHERE user_id = p_user_id;
  IF NOT FOUND THEN RETURN 'contributor'; END IF;

  -- Calculate accuracy
  IF (v_stats.reports_confirmed + v_stats.reports_rejected) > 0 THEN
    v_accuracy := v_stats.reports_confirmed::NUMERIC / (v_stats.reports_confirmed + v_stats.reports_rejected);
  ELSE
    v_accuracy := 0;
  END IF;

  -- Determine tier
  IF v_stats.reports_confirmed >= 20 AND v_accuracy >= 0.8 THEN
    v_new_tier := 'core_qa';
  ELSIF v_stats.reports_confirmed >= 5 AND v_accuracy >= 0.6 THEN
    v_new_tier := 'bug_hunter';
  ELSE
    v_new_tier := 'contributor';
  END IF;

  -- Update
  UPDATE public.qa_tester_stats SET
    tier = v_new_tier,
    accuracy_rate = ROUND(v_accuracy, 3),
    tier_updated_at = CASE WHEN tier != v_new_tier THEN now() ELSE tier_updated_at END
  WHERE user_id = p_user_id;

  RETURN v_new_tier;
END;
$$;


--
-- Name: qa_update_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.qa_update_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


--
-- Name: radio_award_listen_xp(uuid, uuid, integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer DEFAULT 0, p_reaction text DEFAULT NULL::text, p_session_id text DEFAULT NULL::text, p_ip_hash text DEFAULT NULL::text) RETURNS jsonb
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


--
-- Name: radio_award_listen_xp(uuid, uuid, integer, integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text DEFAULT NULL::text, p_session_id text DEFAULT NULL::text, p_ip_hash text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_cfg JSONB;
  v_listen_pct NUMERIC;
  v_xp INTEGER := 0;
  v_xp_today INTEGER;
  v_daily_cap INTEGER;
  v_diminish_after INTEGER;
  v_diminish_rate NUMERIC;
  v_min_pct NUMERIC;
  v_listens_today INTEGER;
  v_result JSONB;
  v_last_listen TIMESTAMPTZ;
  v_same_track_count INTEGER;
  v_ip_session_count INTEGER;
BEGIN
  -- Check if user is blocked
  IF public.is_user_blocked(p_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_blocked');
  END IF;

  -- *** ANTI-ABUSE: Cooldown — min 10 seconds between award calls ***
  SELECT MAX(created_at) INTO v_last_listen
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at > now() - INTERVAL '10 seconds';

  IF v_last_listen IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cooldown', 'reason', 'min 10 sec between listens');
  END IF;

  -- *** ANTI-ABUSE: Same track spam — max 3 rewards per track per day ***
  SELECT COUNT(*) INTO v_same_track_count
  FROM public.radio_listens
  WHERE user_id = p_user_id AND track_id = p_track_id
    AND created_at >= CURRENT_DATE AND xp_earned > 0;

  IF v_same_track_count >= 3 THEN
    -- Still record but no XP
    INSERT INTO public.radio_listens (
      user_id, track_id, listen_duration_sec, track_duration_sec,
      listen_percent, xp_earned, reaction, session_id, ip_hash
    ) VALUES (
      p_user_id, p_track_id, LEAST(p_listen_duration_sec, p_track_duration_sec),
      p_track_duration_sec, 0, 0, p_reaction, p_session_id, p_ip_hash
    );
    RETURN jsonb_build_object('ok', true, 'xp_earned', 0, 'reason', 'same_track_limit');
  END IF;

  -- *** ANTI-ABUSE: IP-based bot detection — max 5 sessions per IP ***
  IF p_ip_hash IS NOT NULL THEN
    SELECT COUNT(DISTINCT session_id) INTO v_ip_session_count
    FROM public.radio_listens
    WHERE ip_hash = p_ip_hash AND created_at >= CURRENT_DATE
      AND session_id != COALESCE(p_session_id, '');

    IF v_ip_session_count >= 5 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ip_limit', 'reason', 'too many sessions from same IP');
    END IF;
  END IF;

  -- *** ANTI-ABUSE: Clamp listen_duration to physical reality ***
  -- Cannot listen longer than track duration + 10% tolerance
  IF p_track_duration_sec > 0 THEN
    p_listen_duration_sec := LEAST(p_listen_duration_sec,
      CEIL(p_track_duration_sec * 1.1)::integer);
  END IF;

  -- Load config
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'listen_to_earn';

  v_daily_cap := COALESCE((v_cfg->>'xp_daily_cap')::int, 100);
  v_diminish_after := COALESCE((v_cfg->>'xp_diminishing_after')::int, 20);
  v_diminish_rate := COALESCE((v_cfg->>'xp_diminishing_rate')::numeric, 0.5);
  v_min_pct := COALESCE((v_cfg->>'min_listen_percent')::numeric, 60);

  -- Calculate listen percentage (clamped to 0-100)
  v_listen_pct := CASE
    WHEN p_track_duration_sec > 0 THEN LEAST(p_listen_duration_sec::numeric / p_track_duration_sec * 100, 100)
    ELSE 0
  END;

  -- Check daily XP cap
  SELECT COALESCE(SUM(xp_earned), 0) INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  IF v_xp_today >= v_daily_cap THEN
    -- Still record the listen, but no XP
    INSERT INTO public.radio_listens (
      user_id, track_id, listen_duration_sec, track_duration_sec,
      listen_percent, xp_earned, reaction, session_id, ip_hash
    ) VALUES (
      p_user_id, p_track_id, p_listen_duration_sec, p_track_duration_sec,
      v_listen_pct, 0, p_reaction, p_session_id, p_ip_hash
    );
    RETURN jsonb_build_object('ok', true, 'xp_earned', 0, 'reason', 'daily_cap_reached',
      'xp_today', v_xp_today, 'daily_cap', v_daily_cap);
  END IF;

  -- Count today's listens for diminishing returns
  SELECT COUNT(*) INTO v_listens_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE AND xp_earned > 0;

  -- Base XP for full listen
  IF v_listen_pct >= v_min_pct THEN
    v_xp := COALESCE((v_cfg->>'xp_per_full_listen')::int, 2);
  END IF;

  -- Bonus XP for reaction
  IF p_reaction IS NOT NULL AND p_reaction != 'skip' THEN
    v_xp := v_xp + COALESCE((v_cfg->>'xp_per_reaction')::int, 1);
  END IF;

  -- Apply diminishing returns
  IF v_listens_today >= v_diminish_after THEN
    v_xp := GREATEST(FLOOR(v_xp * POWER(v_diminish_rate,
      (v_listens_today - v_diminish_after + 1)::numeric / 10)), 1);
  END IF;

  -- Cap to daily limit
  v_xp := LEAST(v_xp, v_daily_cap - v_xp_today);

  -- Record listen
  INSERT INTO public.radio_listens (
    user_id, track_id, listen_duration_sec, track_duration_sec,
    listen_percent, xp_earned, reaction, session_id, ip_hash
  ) VALUES (
    p_user_id, p_track_id, p_listen_duration_sec, p_track_duration_sec,
    v_listen_pct, v_xp, p_reaction, p_session_id, p_ip_hash
  );

  -- Award XP via reputation system (correct parameter order)
  IF v_xp > 0 THEN
    PERFORM public.safe_award_xp(p_user_id, 'radio_listen', 'track', p_track_id, jsonb_build_object('listen_pct', v_listen_pct));
  END IF;

  -- Update track plays_count
  UPDATE public.tracks SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id AND v_listen_pct >= v_min_pct;

  RETURN jsonb_build_object(
    'ok', true,
    'xp_earned', v_xp,
    'listen_percent', ROUND(v_listen_pct, 1),
    'xp_today', v_xp_today + v_xp,
    'daily_cap', v_daily_cap,
    'listens_today', v_listens_today + 1,
    'diminishing', v_listens_today >= v_diminish_after
  );
END;
$$;


--
-- Name: radio_place_bid(uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_cfg JSONB;
  v_slot RECORD;
  v_min_bid NUMERIC;
  v_bid_step NUMERIC;
  v_current_max NUMERIC;
  v_user_balance NUMERIC;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'auction';

  v_min_bid := COALESCE((v_cfg->>'min_bid_rub')::numeric, 10);
  v_bid_step := COALESCE((v_cfg->>'bid_step_rub')::numeric, 5);

  -- *** CRITICAL: Lock slot row to serialize concurrent bids ***
  SELECT * INTO v_slot FROM public.radio_slots
  WHERE id = p_slot_id AND status IN ('open', 'bidding')
  FOR UPDATE;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  -- Lock user balance row to prevent double-spend
  SELECT COALESCE(balance, 0) INTO v_user_balance FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;
  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Check minimum bid (serialized — safe from TOCTOU)
  SELECT COALESCE(MAX(amount), 0) INTO v_current_max FROM public.radio_bids
  WHERE slot_id = p_slot_id AND status = 'active';

  IF p_amount < GREATEST(v_min_bid, v_current_max + v_bid_step) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low',
      'min_required', GREATEST(v_min_bid, v_current_max + v_bid_step));
  END IF;

  -- Refund previous bids from this user on this slot
  -- (return money BEFORE deducting new bid)
  UPDATE public.profiles SET balance = balance + rb.amount
  FROM (SELECT amount FROM public.radio_bids
        WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active') rb
  WHERE user_id = p_user_id;

  UPDATE public.radio_bids SET status = 'refunded'
  WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active';

  -- Refund ALL other active bidders on this slot (outbid)
  UPDATE public.profiles p SET balance = p.balance + rb.amount
  FROM public.radio_bids rb
  WHERE rb.slot_id = p_slot_id AND rb.status = 'active'
    AND rb.user_id != p_user_id AND rb.user_id = p.user_id;

  UPDATE public.radio_bids SET status = 'outbid'
  WHERE slot_id = p_slot_id AND status = 'active' AND user_id != p_user_id;

  -- Hold funds: deduct new bid from balance
  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;

  -- Place new bid (only active bid on this slot after cleanup above)
  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount, status)
  VALUES (p_slot_id, p_user_id, p_track_id, p_amount, 'active');

  -- Update slot status
  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1
  WHERE id = p_slot_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$$;


--
-- Name: radio_place_prediction(uuid, uuid, numeric, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_place_prediction(p_user_id uuid, p_track_id uuid, p_bet_amount numeric, p_predicted_hit boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_cfg JSONB;
  v_min_bet NUMERIC;
  v_max_bet NUMERIC;
  v_window_hours INTEGER;
  v_user_balance NUMERIC;
  v_track_author UUID;
  v_account_age_days INTEGER;
  v_daily_predictions INTEGER;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'predictions';

  v_min_bet := COALESCE((v_cfg->>'bet_min_rub')::numeric, 5);
  v_max_bet := COALESCE((v_cfg->>'bet_max_rub')::numeric, 100);
  v_window_hours := COALESCE((v_cfg->>'hit_window_hours')::int, 24);

  IF p_bet_amount < v_min_bet OR p_bet_amount > v_max_bet THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bet_amount',
      'min', v_min_bet, 'max', v_max_bet);
  END IF;

  -- *** ANTI-ABUSE: Author cannot bet on own track ***
  SELECT user_id INTO v_track_author FROM public.tracks WHERE id = p_track_id;
  IF v_track_author = p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_prediction_forbidden',
      'reason', 'Cannot predict on your own track');
  END IF;

  -- *** ANTI-ABUSE: Min account age 7 days ***
  SELECT EXTRACT(DAY FROM (now() - created_at))::integer INTO v_account_age_days
  FROM public.profiles WHERE user_id = p_user_id;
  IF COALESCE(v_account_age_days, 0) < 7 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_too_new',
      'reason', 'Account must be at least 7 days old');
  END IF;

  -- *** ANTI-ABUSE: Max 10 predictions per day per user ***
  SELECT COUNT(*) INTO v_daily_predictions
  FROM public.radio_predictions
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_daily_predictions >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_prediction_limit');
  END IF;

  -- Check balance (with row lock to prevent double-spend)
  SELECT COALESCE(balance, 0) INTO v_user_balance FROM public.profiles
  WHERE user_id = p_user_id FOR UPDATE;
  IF v_user_balance < p_bet_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Check no existing prediction on this track
  IF EXISTS (SELECT 1 FROM public.radio_predictions
    WHERE user_id = p_user_id AND track_id = p_track_id AND status = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_predicted');
  END IF;

  -- Deduct bet (safe: row already locked above)
  UPDATE public.profiles SET balance = balance - p_bet_amount WHERE user_id = p_user_id;

  -- Create prediction
  INSERT INTO public.radio_predictions (
    user_id, track_id, bet_amount, predicted_hit, expires_at
  ) VALUES (
    p_user_id, p_track_id, p_bet_amount, p_predicted_hit,
    now() + (v_window_hours || ' hours')::interval
  );

  RETURN jsonb_build_object('ok', true, 'bet_amount', p_bet_amount,
    'predicted_hit', p_predicted_hit, 'expires_in_hours', v_window_hours);
END;
$$;


--
-- Name: radio_resolve_predictions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_resolve_predictions() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_cfg JSONB;
  v_threshold INTEGER;
  v_multiplier NUMERIC;
  v_commission NUMERIC;
  v_burn NUMERIC;
  v_count INTEGER := 0;
  rec RECORD;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'predictions';

  v_threshold := COALESCE((v_cfg->>'hit_threshold_likes')::int, 10);
  v_multiplier := COALESCE((v_cfg->>'payout_multiplier')::numeric, 1.8);
  v_commission := COALESCE((v_cfg->>'platform_commission_percent')::numeric, 10) / 100;
  v_burn := COALESCE((v_cfg->>'burn_percent')::numeric, 5) / 100;

  FOR rec IN
    SELECT rp.*, t.likes_count
    FROM public.radio_predictions rp
    JOIN public.tracks t ON t.id = rp.track_id
    WHERE rp.status = 'pending' AND rp.expires_at <= now()
  LOOP
    -- Determine if track is a hit
    IF rec.likes_count >= v_threshold THEN
      -- Track is a hit
      IF rec.predicted_hit THEN
        -- Correct prediction: payout
        UPDATE public.radio_predictions SET
          status = 'won', actual_result = true,
          payout = rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE id = rec.id;
        -- Credit winnings
        UPDATE public.profiles SET balance = balance + rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE user_id = rec.user_id;
        -- Award XP (correct parameter order: user, event, source_type, source_id, metadata)
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_correct', 'track', rec.track_id, '{}'::jsonb);
      ELSE
        -- Wrong prediction: lose bet
        UPDATE public.radio_predictions SET status = 'lost', actual_result = true WHERE id = rec.id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_wrong', 'track', rec.track_id, '{}'::jsonb);
      END IF;
    ELSE
      -- Track is not a hit
      IF NOT rec.predicted_hit THEN
        -- Correct: payout
        UPDATE public.radio_predictions SET
          status = 'won', actual_result = false,
          payout = rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE id = rec.id;
        UPDATE public.profiles SET balance = balance + rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE user_id = rec.user_id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_correct', 'track', rec.track_id, '{}'::jsonb);
      ELSE
        -- Wrong: lose bet
        UPDATE public.radio_predictions SET status = 'lost', actual_result = false WHERE id = rec.id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_wrong', 'track', rec.track_id, '{}'::jsonb);
      END IF;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


--
-- Name: radio_skip_ad(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_skip_ad(p_user_id uuid, p_ad_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_price NUMERIC;
  v_balance NUMERIC;
BEGIN
  -- Get skip price from config
  SELECT COALESCE((value->>'skip_ad_price_rub')::numeric, 5) INTO v_price
  FROM public.radio_config WHERE key = 'advertising';

  -- Lock user balance row (prevents double-spend, race condition)
  SELECT COALESCE(balance, 0) INTO v_balance
  FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;

  IF v_balance < v_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
      'balance', v_balance, 'price', v_price);
  END IF;

  -- Atomic deduction
  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = p_user_id;

  -- Track the skip if ad_id provided
  IF p_ad_id IS NOT NULL THEN
    UPDATE public.radio_ad_placements
    SET clicks = COALESCE(clicks, 0) + 1
    WHERE id = p_ad_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'charged', v_price, 'new_balance', v_balance - v_price);
END;
$$;


--
-- Name: recalculate_feed_scores(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalculate_feed_scores(p_track_id uuid DEFAULT NULL::uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_weights JSONB;
  v_decay JSONB;
  v_tier_weights JSONB;
  v_qg JSONB;
  v_count INTEGER := 0;
  v_half_life NUMERIC;
  rec RECORD;
BEGIN
  SELECT value INTO v_weights FROM feed_config WHERE key = 'ranking_weights';
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_tier_weights FROM feed_config WHERE key = 'tier_weights';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';

  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  FOR rec IN
    SELECT t.id AS track_id,
           COALESCE(t.likes_count, 0) AS likes,
           COALESCE(t.plays_count, 0) AS plays,
           (SELECT COUNT(*) FROM public.track_comments tc WHERE tc.track_id = t.id) AS comments,
           COALESCE(t.shares_count, 0) AS shares,
           (SELECT COUNT(*) FROM public.playlist_tracks pt WHERE pt.track_id = t.id) AS saves,
           t.created_at,
           COALESCE(tqs.quality_score, 5) AS quality,
           -- Velocity: engagement in last 24h
           (SELECT COUNT(*) FROM public.track_likes tl
            WHERE tl.track_id = t.id AND tl.created_at > now() - interval '1 hour') AS likes_1h,
           (SELECT COUNT(*) FROM public.track_likes tl
            WHERE tl.track_id = t.id AND tl.created_at > now() - interval '24 hours') AS likes_24h
    FROM public.tracks t
    LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
    WHERE t.is_public = true AND t.status = 'completed'
      AND (p_track_id IS NULL OR t.id = p_track_id)
      AND t.created_at > now() - interval '30 days'
  LOOP
    INSERT INTO public.track_feed_scores (
      track_id, raw_engagement, weighted_engagement,
      velocity_1h, velocity_24h, time_decay_factor,
      final_score, is_spam, calculated_at
    ) VALUES (
      rec.track_id,
      -- Raw engagement
      rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
      rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
      rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
      rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
      rec.saves * COALESCE((v_weights->>'saves')::numeric, 10),
      -- Weighted (with quality)
      (rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
       rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
       rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
       rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
       rec.saves * COALESCE((v_weights->>'saves')::numeric, 10))
      * GREATEST(rec.quality / 10.0, 0.1),
      -- Velocity 1h
      rec.likes_1h * 10,
      -- Velocity 24h
      rec.likes_24h,
      -- Time decay
      POWER(0.5, EXTRACT(EPOCH FROM (now() - rec.created_at)) / 3600 / v_half_life),
      -- Final score
      (rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
       rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
       rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
       rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
       rec.saves * COALESCE((v_weights->>'saves')::numeric, 10))
      * GREATEST(rec.quality / 10.0, 0.1)
      * POWER(0.5, EXTRACT(EPOCH FROM (now() - rec.created_at)) / 3600 / v_half_life),
      -- Spam check
      rec.quality < COALESCE((v_qg->>'spam_threshold')::numeric, 1.0),
      now()
    )
    ON CONFLICT (track_id) DO UPDATE SET
      raw_engagement = EXCLUDED.raw_engagement,
      weighted_engagement = EXCLUDED.weighted_engagement,
      velocity_1h = EXCLUDED.velocity_1h,
      velocity_24h = EXCLUDED.velocity_24h,
      time_decay_factor = EXCLUDED.time_decay_factor,
      final_score = EXCLUDED.final_score,
      is_spam = EXCLUDED.is_spam,
      calculated_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


--
-- Name: record_ad_click(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_ad_click(p_impression_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_campaign_id uuid;
BEGIN
  -- Обновить impression
  UPDATE public.ad_impressions
  SET clicked_at = now(), is_click = true
  WHERE id = p_impression_id
  RETURNING campaign_id INTO v_campaign_id;

  -- Обновить счётчик кампании
  IF v_campaign_id IS NOT NULL THEN
    UPDATE public.ad_campaigns
    SET clicks_count = COALESCE(clicks_count, 0) + 1,
        clicks = COALESCE(clicks, 0) + 1
    WHERE id = v_campaign_id;
  END IF;
END;
$$;


--
-- Name: record_ad_impression(uuid, uuid, text, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_ad_impression(p_campaign_id uuid, p_creative_id uuid, p_slot_key text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid, p_device_type text DEFAULT 'desktop'::text, p_page_url text DEFAULT NULL::text, p_session_id text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_slot_id uuid;
  v_impression_id uuid;
BEGIN
  -- Найти slot_id по ключу (если передан)
  IF p_slot_key IS NOT NULL THEN
    SELECT id INTO v_slot_id FROM public.ad_slots WHERE slot_key = p_slot_key LIMIT 1;
  END IF;

  INSERT INTO public.ad_impressions (
    campaign_id, creative_id, slot_id, user_id,
    device_type, page_url, viewed_at, session_id
  ) VALUES (
    p_campaign_id, p_creative_id, v_slot_id, p_user_id,
    p_device_type, p_page_url, now(), p_session_id
  )
  RETURNING id INTO v_impression_id;

  -- Обновить счётчик кампании
  UPDATE public.ad_campaigns
  SET impressions_count = COALESCE(impressions_count, 0) + 1,
      impressions = COALESCE(impressions, 0) + 1
  WHERE id = p_campaign_id;

  RETURN v_impression_id;
END;
$$;


--
-- Name: resolve_qa_ticket(uuid, text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_qa_ticket(p_ticket_id uuid, p_status text, p_notes text DEFAULT NULL::text, p_reward_xp integer DEFAULT 0, p_reward_credits integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_admin_id UUID;
  v_reporter_id UUID;
  v_old_status TEXT;
  v_bounty_id UUID;
  v_severity TEXT;
  v_bounty RECORD;
  v_final_xp INTEGER;
  v_final_credits INTEGER;
  v_rep INTEGER;
  v_tier RECORD;
  v_rewards_config JSONB;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT reporter_id, status, bounty_id, severity INTO v_reporter_id, v_old_status, v_bounty_id, v_severity
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

  -- Fallback: если credits начисляются, а xp = 0 — взять XP из qa_config по severity
  IF v_final_credits > 0 AND v_final_xp = 0 AND v_severity IS NOT NULL THEN
    SELECT value INTO v_rewards_config FROM public.qa_config WHERE key = 'rewards';
    IF v_rewards_config IS NOT NULL THEN
      v_final_xp := COALESCE((v_rewards_config->>(v_severity || '_xp'))::INTEGER, 0);
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

    -- XP: прямое начисление в forum_user_stats
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
$$;


--
-- Name: resolve_track_voting(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_track_voting(p_track_id uuid, p_result text DEFAULT 'approved'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.tracks
  SET moderation_status = CASE WHEN p_result = 'approved' THEN 'approved' ELSE 'rejected' END,
      voting_result = p_result
  WHERE id = p_track_id;
END;
$$;


--
-- Name: revoke_share_token(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_share_token(p_track_id uuid, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.tracks SET share_token = NULL WHERE id = p_track_id AND user_id = p_user_id;
END;
$$;


--
-- Name: revoke_verification(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_verification(_user_id text, _admin_id text, _reason text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid UUID := _user_id::uuid;
  v_adm UUID := _admin_id::uuid;
BEGIN
  IF NOT is_admin(v_adm) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE profiles SET
    is_verified = false,
    verified_at = NULL,
    verified_by = NULL,
    verification_type = NULL
  WHERE user_id = v_uid AND is_verified = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not verified';
  END IF;

  INSERT INTO notifications (user_id, actor_id, type, title, message)
  VALUES (
    v_uid, v_adm,
    'system',
    '?????????????????????? ????????????????',
    '?????? ???????????? ?????????????????????? ?????? ??????????????.' ||
      CASE WHEN _reason IS NOT NULL THEN ' ??????????????: ' || _reason ELSE '' END
  );

  RETURN true;
END;
$$;


--
-- Name: safe_award_xp(uuid, text, text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.safe_award_xp(p_user_id uuid, p_event_type text, p_source_type text DEFAULT NULL::text, p_source_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  PERFORM public.award_xp(p_user_id, p_event_type, p_source_type, p_source_id, p_metadata);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'safe_award_xp(%, %) failed: %', p_user_id, p_event_type, SQLERRM;
END;
$$;


--
-- Name: send_track_to_voting(uuid, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_track_to_voting(p_track_id uuid, p_duration_days integer DEFAULT NULL::integer, p_voting_type text DEFAULT 'public'::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_duration interval;
BEGIN
  -- Calculate duration
  IF p_duration_days IS NOT NULL AND p_duration_days > 0 THEN
    v_duration := (p_duration_days || ' days')::interval;
  ELSIF p_voting_type = 'internal' THEN
    v_duration := interval '1 day';
  ELSE
    v_duration := interval '7 days';
  END IF;

  UPDATE public.tracks
  SET moderation_status = 'voting',
      voting_started_at = now(),
      voting_ends_at = now() + v_duration,
      voting_type = p_voting_type,
      voting_likes_count = 0,
      voting_dislikes_count = 0,
      voting_result = NULL
  WHERE id = p_track_id;

  RETURN FOUND;
END;
$$;


--
-- Name: submit_contest_entry(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_contest_entry(p_contest_id uuid, p_track_id uuid, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: unblock_user(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unblock_user(p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM public.user_blocks WHERE user_id = p_user_id;
  UPDATE public.profiles
  SET is_blocked = false, blocked_at = NULL, blocked_reason = NULL, blocked_by = NULL
  WHERE user_id = p_user_id;
END;
$$;


--
-- Name: unhide_contest_comment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unhide_contest_comment(p_comment_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.contest_entry_comments SET is_hidden = false WHERE id = p_comment_id;
END;
$$;


--
-- Name: update_last_seen(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_last_seen() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.profiles 
  SET last_seen_at = now() 
  WHERE user_id = auth.uid();
END;
$$;


--
-- Name: update_last_seen(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_last_seen(p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.profiles SET last_seen_at = now() WHERE user_id = p_user_id;
END;
$$;


--
-- Name: update_total_votes_received(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_total_votes_received() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: vote_qa_ticket(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vote_qa_ticket(p_ticket_id uuid, p_vote_type text DEFAULT 'confirm'::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id UUID;
  v_voter_weight NUMERIC;
  v_ticket_reporter UUID;
  v_existing UUID;
  v_new_count INTEGER;
  v_threshold INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- Can't vote on own ticket
  SELECT reporter_id INTO v_ticket_reporter FROM public.qa_tickets WHERE id = p_ticket_id;
  IF v_ticket_reporter = v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot vote on own ticket');
  END IF;

  -- Check for existing vote
  SELECT id INTO v_existing FROM public.qa_votes
    WHERE ticket_id = p_ticket_id AND user_id = v_user_id AND vote_type = p_vote_type;
  IF v_existing IS NOT NULL THEN
    -- Remove vote
    DELETE FROM public.qa_votes WHERE id = v_existing;
    UPDATE public.qa_tickets
      SET upvotes = GREATEST(0, upvotes - 1),
          verification_count = CASE WHEN p_vote_type = 'confirm'
            THEN GREATEST(0, verification_count - 1) ELSE verification_count END
      WHERE id = p_ticket_id;
    RETURN jsonb_build_object('success', true, 'action', 'removed');
  END IF;

  -- Get voter weight from reputation tier
  SELECT COALESCE(vote_weight, 1.0) INTO v_voter_weight
    FROM public.forum_user_stats WHERE user_id = v_user_id;
  IF v_voter_weight IS NULL THEN v_voter_weight := 1.0; END IF;

  -- Insert vote
  INSERT INTO public.qa_votes (ticket_id, user_id, vote_type, voter_weight)
    VALUES (p_ticket_id, v_user_id, p_vote_type, v_voter_weight);

  -- Update ticket counts
  UPDATE public.qa_tickets
    SET upvotes = upvotes + 1,
        verification_count = CASE WHEN p_vote_type = 'confirm'
          THEN verification_count + 1 ELSE verification_count END
    WHERE id = p_ticket_id
    RETURNING verification_count INTO v_new_count;

  -- Auto-verify if threshold reached
  SELECT COALESCE((value->>'confirmation_threshold')::INTEGER, 3) INTO v_threshold
    FROM public.qa_config WHERE key = 'general';

  IF v_new_count >= v_threshold THEN
    UPDATE public.qa_tickets
      SET is_verified = true, verified_at = now(), status = CASE WHEN status = 'new' THEN 'confirmed' ELSE status END
      WHERE id = p_ticket_id AND NOT is_verified;
  END IF;

  -- Recalculate priority
  PERFORM public.qa_recalculate_priority(p_ticket_id);

  -- Award XP for voting
  UPDATE public.qa_tester_stats
    SET votes_cast = votes_cast + 1
    WHERE user_id = v_user_id;
  INSERT INTO public.qa_tester_stats (user_id, votes_cast)
    VALUES (v_user_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET votes_cast = qa_tester_stats.votes_cast + 1;

  RETURN jsonb_build_object('success', true, 'action', 'added', 'verification_count', v_new_count);
END;
$$;


--
-- Name: withdraw_contest_entry(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.withdraw_contest_entry(p_entry_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM public.contest_entries WHERE id = p_entry_id AND user_id = p_user_id;
  RETURN FOUND;
END;
$$;


--
-- Name: users; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text,
    encrypted_password text,
    email_confirmed_at timestamp with time zone,
    raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_sign_in_at timestamp with time zone,
    is_super_admin boolean DEFAULT false
);


--
-- Name: achievements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.achievements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    name_ru text,
    description text,
    icon text,
    category text DEFAULT 'general'::text,
    xp_reward integer DEFAULT 0,
    condition_type text,
    condition_value integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    key text,
    description_ru text,
    rarity text DEFAULT 'common'::text,
    requirement_type text DEFAULT 'manual'::text,
    requirement_value integer DEFAULT 1,
    credit_reward integer DEFAULT 0,
    sort_order integer DEFAULT 0
);


--
-- Name: ad_campaign_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_campaign_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    slot_id uuid,
    priority integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    is_active boolean DEFAULT true,
    priority_override integer
);


--
-- Name: ad_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slot_key text,
    status text DEFAULT 'draft'::text,
    budget numeric DEFAULT 0,
    spent numeric DEFAULT 0,
    impressions integer DEFAULT 0,
    clicks integer DEFAULT 0,
    image_url text,
    link_url text,
    html_content text,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    targeting jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    description text,
    advertiser_name text,
    advertiser_url text,
    campaign_type text DEFAULT 'external'::text,
    internal_type text,
    internal_id uuid,
    budget_daily integer,
    budget_total integer,
    impressions_count integer DEFAULT 0,
    clicks_count integer DEFAULT 0,
    priority integer DEFAULT 50,
    created_by uuid
);


--
-- Name: ad_creatives; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_creatives (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    type text DEFAULT 'image'::text,
    title text,
    description text,
    media_url text,
    click_url text,
    cta_text text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    creative_type text DEFAULT 'image'::text,
    subtitle text,
    media_type text,
    thumbnail_url text,
    external_video_url text,
    variant text DEFAULT 'default'::text,
    width integer,
    height integer,
    aspect_ratio text
);


--
-- Name: ad_impressions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_impressions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    creative_id uuid,
    slot_id uuid,
    user_id uuid,
    ip_address text,
    is_click boolean DEFAULT false,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    device_type text,
    page_url text,
    viewed_at timestamp with time zone DEFAULT now(),
    view_duration_ms integer,
    clicked_at timestamp with time zone,
    session_id text
);


--
-- Name: ad_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value text DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    description text
);


--
-- Name: ad_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slot_type text NOT NULL,
    description text,
    width integer,
    height integer,
    is_active boolean DEFAULT true,
    base_price numeric DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    slot_key text,
    is_enabled boolean DEFAULT true,
    max_ads integer DEFAULT 1,
    recommended_width integer,
    recommended_height integer,
    recommended_aspect_ratio text,
    supported_types text[],
    frequency_cap integer DEFAULT 10,
    cooldown_seconds integer DEFAULT 60,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: ad_targeting; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_targeting (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    target_type text,
    target_value text,
    created_at timestamp with time zone DEFAULT now(),
    target_free_users boolean DEFAULT true,
    target_subscribed_users boolean DEFAULT true,
    target_mobile boolean DEFAULT true,
    target_desktop boolean DEFAULT true,
    min_generations integer,
    max_generations integer,
    min_days_registered integer,
    show_hours_start integer,
    show_hours_end integer,
    show_days_of_week integer[],
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: addon_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addon_services (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    name_ru text,
    description text,
    description_ru text,
    price_rub integer DEFAULT 0,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    category text DEFAULT 'audio'::text,
    icon text,
    created_at timestamp with time zone DEFAULT now(),
    price_aipci numeric DEFAULT 0,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: admin_announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_announcements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text,
    content text,
    type text DEFAULT 'info'::text,
    is_published boolean DEFAULT false,
    publish_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: admin_emails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_emails (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sender_id uuid,
    sender_type text DEFAULT 'project'::text,
    recipient_id uuid,
    recipient_email text,
    subject text,
    body_html text,
    template_id uuid,
    status text DEFAULT 'pending'::text,
    error_message text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: ai_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_models (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    version text NOT NULL,
    description text,
    is_hot boolean DEFAULT false,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_provider_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_provider_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text NOT NULL,
    api_key_encrypted text,
    base_url text,
    model_name text,
    settings jsonb DEFAULT '{}'::jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: announcement_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcement_dismissals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    announcement_id uuid,
    user_id uuid,
    dismissed_at timestamp with time zone DEFAULT now()
);


--
-- Name: announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    content text NOT NULL,
    type text DEFAULT 'info'::text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    expires_at timestamp with time zone
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    name text NOT NULL,
    key_hash text NOT NULL,
    prefix text,
    permissions jsonb DEFAULT '[]'::jsonb,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: artist_styles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artist_styles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: attribution_pools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attribution_pools (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    ad_revenue_total numeric(12,2) DEFAULT 0,
    subscription_share_total numeric(12,2) DEFAULT 0,
    marketplace_commission_total numeric(12,2) DEFAULT 0,
    bonus_pool numeric(12,2) DEFAULT 0,
    total_pool numeric(12,2) DEFAULT 0,
    total_distributed numeric(12,2) DEFAULT 0,
    total_eligible_creators integer DEFAULT 0,
    total_engagement_points bigint DEFAULT 0,
    status text DEFAULT 'accumulating'::text,
    calculated_at timestamp with time zone,
    distributed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT attribution_pools_status_check CHECK ((status = ANY (ARRAY['accumulating'::text, 'calculating'::text, 'distributed'::text, 'archived'::text])))
);


--
-- Name: attribution_shares; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attribution_shares (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pool_id uuid NOT NULL,
    user_id uuid NOT NULL,
    total_plays bigint DEFAULT 0,
    unique_listeners integer DEFAULT 0,
    total_likes integer DEFAULT 0,
    total_shares integer DEFAULT 0,
    total_comments integer DEFAULT 0,
    total_saves integer DEFAULT 0,
    engagement_score numeric(14,2) DEFAULT 0,
    tier_multiplier numeric(3,2) DEFAULT 1.0,
    quality_multiplier numeric(3,2) DEFAULT 1.0,
    weighted_score numeric(14,2) DEFAULT 0,
    pool_share_percent numeric(8,6) DEFAULT 0,
    earned_amount numeric(12,2) DEFAULT 0,
    paid_out boolean DEFAULT false,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: audio_separations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audio_separations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    type text DEFAULT 'vocal'::text,
    status text DEFAULT 'pending'::text,
    source_url text,
    result_urls jsonb,
    error_message text,
    price_rub integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: balance_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.balance_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    amount integer NOT NULL,
    type text NOT NULL,
    description text,
    reference_type text,
    reference_id uuid,
    balance_before integer DEFAULT 0,
    balance_after integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: beat_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.beat_purchases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    beat_id uuid,
    buyer_id uuid,
    seller_id uuid,
    price integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    license_type text DEFAULT 'basic'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: bug_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bug_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text,
    description text,
    steps_to_reproduce text,
    expected_behavior text,
    actual_behavior text,
    severity text DEFAULT 'medium'::text,
    status text DEFAULT 'open'::text,
    screenshot_url text,
    browser_info jsonb DEFAULT '{}'::jsonb,
    assigned_to uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    report_type text DEFAULT 'bug'::text,
    page_url text,
    user_agent text,
    admin_response text,
    responded_by uuid,
    responded_at timestamp with time zone
);


--
-- Name: challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.challenges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    type text DEFAULT 'daily'::text,
    xp_reward integer DEFAULT 0,
    condition_type text,
    condition_value integer DEFAULT 0,
    is_active boolean DEFAULT true,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: comment_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_likes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: comment_mentions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_mentions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid,
    mentioned_user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: comment_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid,
    user_id uuid,
    emoji text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: comment_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid,
    user_id uuid,
    reason text,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    content text NOT NULL,
    parent_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_achievements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_achievements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    description text,
    icon text DEFAULT '🏆'::text,
    xp_reward integer DEFAULT 0,
    credit_reward integer DEFAULT 0,
    rarity text DEFAULT 'common'::text,
    condition_type text NOT NULL,
    condition_value integer NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT contest_achievements_rarity_check CHECK ((rarity = ANY (ARRAY['common'::text, 'rare'::text, 'epic'::text, 'legendary'::text])))
);


--
-- Name: contest_asset_downloads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_asset_downloads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    user_id uuid,
    asset_url text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_comment_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_comment_likes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    track_id uuid,
    user_id uuid,
    score numeric DEFAULT 0,
    status text DEFAULT 'submitted'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_entry_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_entry_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entry_id uuid,
    user_id uuid,
    content text NOT NULL,
    parent_id uuid,
    likes_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    is_hidden boolean DEFAULT false
);


--
-- Name: contest_jury; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_jury (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    user_id uuid,
    role text DEFAULT 'jury'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_jury_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_jury_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    entry_id uuid,
    jury_id uuid,
    score numeric DEFAULT 0,
    feedback text,
    criteria_scores jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_leagues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_leagues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    tier integer NOT NULL,
    min_rating integer NOT NULL,
    max_rating integer,
    icon_url text,
    color text,
    multiplier numeric(3,2) DEFAULT 1.0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_ratings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_ratings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    rating integer DEFAULT 1000,
    league_id uuid,
    season_points integer DEFAULT 0,
    season_id uuid,
    weekly_points integer DEFAULT 0,
    daily_streak integer DEFAULT 0,
    best_streak integer DEFAULT 0,
    total_contests integer DEFAULT 0,
    total_wins integer DEFAULT 0,
    total_top3 integer DEFAULT 0,
    total_votes_received integer DEFAULT 0,
    last_contest_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_seasons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_seasons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    start_date timestamp with time zone NOT NULL,
    end_date timestamp with time zone NOT NULL,
    status text DEFAULT 'upcoming'::text,
    theme text,
    grand_prize_amount integer DEFAULT 0,
    grand_prize_description text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT contest_seasons_status_check CHECK ((status = ANY (ARRAY['upcoming'::text, 'active'::text, 'completed'::text])))
);


--
-- Name: contest_user_achievements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_user_achievements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    achievement_id uuid NOT NULL,
    earned_at timestamp with time zone DEFAULT now()
);


--
-- Name: contest_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    entry_id uuid,
    user_id uuid,
    score integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    ip_hash text,
    user_agent_hash text,
    is_suspicious boolean DEFAULT false,
    fraud_score numeric(5,2) DEFAULT 0
);


--
-- Name: contest_winners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contest_winners (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contest_id uuid,
    user_id uuid,
    entry_id uuid,
    place integer DEFAULT 1,
    prize_description text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    genre_id uuid,
    status text DEFAULT 'draft'::text,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    prize_description text,
    prize_amount integer DEFAULT 0,
    max_entries integer,
    rules text,
    cover_url text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    contest_type text DEFAULT 'classic'::text,
    entry_fee integer DEFAULT 0,
    min_participants integer DEFAULT 3,
    min_votes_to_win integer DEFAULT 1,
    auto_finalize boolean DEFAULT true,
    season_id uuid,
    theme text,
    prize_pool_formula text DEFAULT 'fixed'::text,
    prize_distribution jsonb DEFAULT '[0.6, 0.3, 0.1]'::jsonb,
    require_new_track boolean DEFAULT false,
    scoring_mode text DEFAULT 'votes'::text,
    voting_end_date timestamp with time zone,
    max_entries_per_user integer DEFAULT 1,
    jury_weight numeric(3,2) DEFAULT 0.5,
    jury_enabled boolean DEFAULT false,
    assets_url text,
    assets_description text,
    is_remix_contest boolean DEFAULT false
);


--
-- Name: conversation_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid,
    user_id uuid,
    last_read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type text DEFAULT 'direct'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    status text DEFAULT 'active'::text,
    closed_by uuid,
    closed_at timestamp with time zone
);


--
-- Name: copyright_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copyright_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    type text DEFAULT 'copyright'::text,
    status text DEFAULT 'pending'::text,
    description text,
    evidence_urls jsonb DEFAULT '[]'::jsonb,
    response text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: creator_earnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creator_earnings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    total_attribution numeric(12,2) DEFAULT 0,
    total_marketplace_sales numeric(12,2) DEFAULT 0,
    total_premium_content numeric(12,2) DEFAULT 0,
    total_tips numeric(12,2) DEFAULT 0,
    total_royalties numeric(12,2) DEFAULT 0,
    total_earned numeric(12,2) DEFAULT 0,
    current_month_attribution numeric(12,2) DEFAULT 0,
    current_month_sales numeric(12,2) DEFAULT 0,
    current_month_total numeric(12,2) DEFAULT 0,
    pending_payout numeric(12,2) DEFAULT 0,
    total_paid_out numeric(12,2) DEFAULT 0,
    last_payout_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: distribution_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.distribution_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    platform text,
    status text DEFAULT 'pending'::text,
    external_id text,
    metadata jsonb DEFAULT '{}'::jsonb,
    error_message text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: distribution_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.distribution_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    platforms jsonb DEFAULT '[]'::jsonb,
    status text DEFAULT 'pending'::text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: economy_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_config (
    key text NOT NULL,
    value jsonb DEFAULT '{}'::jsonb NOT NULL,
    label text,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: economy_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    snapshot_date date NOT NULL,
    total_aipci_in_circulation bigint DEFAULT 0,
    aipci_created_today bigint DEFAULT 0,
    aipci_spent_today bigint DEFAULT 0,
    aipci_velocity numeric(6,4) DEFAULT 0,
    total_users integer DEFAULT 0,
    active_creators integer DEFAULT 0,
    active_listeners integer DEFAULT 0,
    paying_users integer DEFAULT 0,
    daily_subscription_revenue numeric(12,2) DEFAULT 0,
    daily_generation_revenue numeric(12,2) DEFAULT 0,
    daily_marketplace_revenue numeric(12,2) DEFAULT 0,
    daily_ad_revenue numeric(12,2) DEFAULT 0,
    daily_total_revenue numeric(12,2) DEFAULT 0,
    daily_generation_cost numeric(12,2) DEFAULT 0,
    daily_reward_payouts numeric(12,2) DEFAULT 0,
    daily_total_cost numeric(12,2) DEFAULT 0,
    revenue_cost_ratio numeric(6,4) DEFAULT 0,
    creator_payout_ratio numeric(6,4) DEFAULT 0,
    tracks_generated_today integer DEFAULT 0,
    avg_quality_score numeric(4,2) DEFAULT 0,
    spam_rate numeric(6,4) DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: email_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    subject text,
    body_html text,
    variables jsonb DEFAULT '[]'::jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: email_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_verifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    email text NOT NULL,
    code text NOT NULL,
    verified boolean DEFAULT false,
    expires_at timestamp with time zone DEFAULT (now() + '00:15:00'::interval),
    created_at timestamp with time zone DEFAULT now(),
    username text
);


--
-- Name: error_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.error_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    level text DEFAULT 'error'::text,
    message text,
    stack text,
    context jsonb DEFAULT '{}'::jsonb,
    user_id uuid,
    url text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: feature_trials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feature_trials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    feature text NOT NULL,
    uses_remaining integer DEFAULT 0,
    total_uses integer DEFAULT 0,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: feed_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feed_config (
    key text NOT NULL,
    value jsonb DEFAULT '{}'::jsonb NOT NULL,
    label text,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    follower_id uuid,
    following_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_activity_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text NOT NULL,
    target_type text,
    target_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid,
    user_id uuid,
    file_url text NOT NULL,
    file_name text,
    file_size integer,
    mime_type text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_automod_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_automod_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rule_type text NOT NULL,
    pattern text,
    action text DEFAULT 'flag'::text,
    severity text DEFAULT 'low'::text,
    is_active boolean DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_bookmarks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topic_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    description text,
    icon text,
    sort_order integer DEFAULT 0,
    is_hidden boolean DEFAULT false,
    topics_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    name_ru text,
    color text DEFAULT '#6366f1'::text,
    is_active boolean DEFAULT true,
    posts_count integer DEFAULT 0,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_category_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_category_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    category_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_citations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_citations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    article_id uuid NOT NULL,
    citing_topic_id uuid,
    citing_post_id uuid,
    cited_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_content_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_content_purchases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid NOT NULL,
    buyer_id uuid NOT NULL,
    price_paid integer NOT NULL,
    purchased_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_content_quality; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_content_quality (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    content_type text NOT NULL,
    content_id uuid NOT NULL,
    author_id uuid NOT NULL,
    depth_score numeric(4,2) DEFAULT 0,
    usefulness_score numeric(4,2) DEFAULT 0,
    engagement_score numeric(4,2) DEFAULT 0,
    uniqueness_score numeric(4,2) DEFAULT 0,
    overall_quality numeric(4,2) DEFAULT 0,
    word_count integer DEFAULT 0,
    has_code_blocks boolean DEFAULT false,
    has_images boolean DEFAULT false,
    has_links boolean DEFAULT false,
    weighted_votes numeric DEFAULT 0,
    solution_bonus numeric DEFAULT 0,
    computed_at timestamp with time zone DEFAULT now(),
    CONSTRAINT forum_content_quality_content_type_check CHECK ((content_type = ANY (ARRAY['topic'::text, 'post'::text])))
);


--
-- Name: forum_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_drafts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topic_id uuid,
    category_id uuid,
    title text,
    content text,
    is_reply boolean DEFAULT false,
    parent_post_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    draft_type text DEFAULT 'post'::text,
    content_html text,
    tags text[]
);


--
-- Name: forum_hub_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_hub_config (
    key text NOT NULL,
    value jsonb NOT NULL,
    label text,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_knowledge_articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_knowledge_articles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_topic_id uuid,
    title text NOT NULL,
    summary text NOT NULL,
    content text NOT NULL,
    content_html text,
    category text DEFAULT 'guide'::text NOT NULL,
    difficulty text DEFAULT 'intermediate'::text,
    tags text[] DEFAULT '{}'::text[],
    expertise_area text,
    status text DEFAULT 'draft'::text NOT NULL,
    is_featured boolean DEFAULT false,
    is_pinned boolean DEFAULT false,
    author_id uuid NOT NULL,
    curator_id uuid,
    curated_at timestamp with time zone,
    views_count integer DEFAULT 0,
    likes_count integer DEFAULT 0,
    citations_count integer DEFAULT 0,
    quality_score numeric(4,2) DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    published_at timestamp with time zone
);


--
-- Name: forum_link_previews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_link_previews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    url text NOT NULL,
    title text,
    description text,
    image_url text,
    site_name text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_mod_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_mod_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    moderator_id uuid,
    action text NOT NULL,
    target_type text,
    target_id uuid,
    reason text,
    details jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_poll_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_poll_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    poll_id uuid,
    text text NOT NULL,
    votes_count integer DEFAULT 0,
    sort_order integer DEFAULT 0
);


--
-- Name: forum_poll_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_poll_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    poll_id uuid,
    option_id uuid,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_polls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_polls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid,
    question text NOT NULL,
    allow_multiple boolean DEFAULT false,
    anonymous boolean DEFAULT false,
    expires_at timestamp with time zone,
    total_votes integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_post_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_post_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid,
    user_id uuid,
    emoji text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_post_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_post_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid,
    user_id uuid,
    vote_type text DEFAULT 'up'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid,
    user_id uuid,
    content text NOT NULL,
    is_hidden boolean DEFAULT false,
    likes_count integer DEFAULT 0,
    parent_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    is_solution boolean DEFAULT false,
    content_html text,
    votes_score integer DEFAULT 0,
    reply_to_user_id uuid,
    reply_depth integer DEFAULT 0,
    hidden_by uuid,
    hidden_at timestamp with time zone,
    hidden_reason text,
    track_id uuid,
    edit_count integer DEFAULT 0,
    edited_at timestamp with time zone
);


--
-- Name: forum_premium_content; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_premium_content (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid NOT NULL,
    author_id uuid NOT NULL,
    price_credits integer DEFAULT 0 NOT NULL,
    preview_length integer DEFAULT 500,
    is_active boolean DEFAULT true,
    purchases_count integer DEFAULT 0,
    revenue_total integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_promo_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_promo_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid,
    user_id uuid,
    slot_type text DEFAULT 'featured'::text,
    "position" integer DEFAULT 0,
    starts_at timestamp with time zone DEFAULT now(),
    ends_at timestamp with time zone,
    is_active boolean DEFAULT true,
    price integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_read_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_read_status (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topic_id uuid,
    last_read_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reporter_id uuid,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    details text,
    status text DEFAULT 'pending'::text,
    moderator_id uuid,
    resolution text,
    created_at timestamp with time zone DEFAULT now(),
    resolved_at timestamp with time zone
);


--
-- Name: forum_reputation_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_reputation_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    action text NOT NULL,
    points integer DEFAULT 0,
    description text,
    is_active boolean DEFAULT true
);


--
-- Name: forum_reputation_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_reputation_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text,
    points integer DEFAULT 0,
    source_type text,
    source_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_similar_topics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_similar_topics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_a_id uuid NOT NULL,
    topic_b_id uuid NOT NULL,
    similarity_score numeric(4,3) NOT NULL,
    computed_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_staff_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_staff_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    author_id uuid,
    note text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    color text DEFAULT '#888'::text,
    description text,
    usage_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_topic_boosts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topic_boosts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid NOT NULL,
    boosted_by uuid NOT NULL,
    boost_type text DEFAULT 'standard'::text NOT NULL,
    credits_spent integer DEFAULT 0 NOT NULL,
    boost_multiplier numeric(3,1) DEFAULT 1.5,
    starts_at timestamp with time zone DEFAULT now(),
    ends_at timestamp with time zone NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_topic_cluster_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topic_cluster_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cluster_id uuid NOT NULL,
    topic_id uuid NOT NULL,
    similarity_score numeric(4,3) DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_topic_clusters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topic_clusters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    category text,
    topic_count integer DEFAULT 0,
    avg_quality numeric(4,2) DEFAULT 0,
    representative_topic_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_topic_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topic_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topic_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_topic_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topic_tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    topic_id uuid,
    tag_id uuid
);


--
-- Name: forum_topics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_topics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid,
    user_id uuid,
    title text NOT NULL,
    content text,
    is_pinned boolean DEFAULT false,
    is_locked boolean DEFAULT false,
    is_hidden boolean DEFAULT false,
    posts_count integer DEFAULT 0,
    views_count integer DEFAULT 0,
    last_post_at timestamp with time zone,
    last_post_user_id uuid,
    bumped_at timestamp with time zone DEFAULT now(),
    track_id uuid,
    tags text[],
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    is_solved boolean DEFAULT false,
    content_html text,
    excerpt text,
    votes_score integer DEFAULT 0,
    likes_count integer DEFAULT 0,
    word_count integer DEFAULT 0,
    has_poll boolean DEFAULT false
);


--
-- Name: forum_user_bans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_user_bans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    banned_by uuid,
    reason text NOT NULL,
    ban_type text DEFAULT 'temporary'::text,
    expires_at timestamp with time zone,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_user_ignores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_user_ignores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    ignored_user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_user_reads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_user_reads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topic_id uuid,
    last_read_post_id uuid,
    last_read_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_user_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_user_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    topics_count integer DEFAULT 0,
    posts_count integer DEFAULT 0,
    likes_received integer DEFAULT 0,
    likes_given integer DEFAULT 0,
    reputation integer DEFAULT 0,
    solutions_count integer DEFAULT 0,
    warnings_count integer DEFAULT 0,
    trust_level integer DEFAULT 0,
    joined_at timestamp with time zone DEFAULT now(),
    last_post_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now(),
    xp_total integer DEFAULT 0,
    xp_forum integer DEFAULT 0,
    xp_music integer DEFAULT 0,
    xp_social integer DEFAULT 0,
    xp_daily_earned integer DEFAULT 0,
    xp_daily_date date DEFAULT CURRENT_DATE,
    featured_badges uuid[] DEFAULT '{}'::uuid[],
    hide_forum_activity boolean DEFAULT false,
    hide_online_status boolean DEFAULT false,
    tier text DEFAULT 'newcomer'::text,
    tier_progress integer DEFAULT 0,
    vote_weight numeric(3,2) DEFAULT 1.0,
    curator_score integer DEFAULT 0,
    quality_ratio numeric(4,3) DEFAULT 0.0,
    tracks_published integer DEFAULT 0,
    tracks_liked_received integer DEFAULT 0,
    guides_published integer DEFAULT 0,
    collaborations_count integer DEFAULT 0,
    total_play_time_seconds bigint DEFAULT 0,
    streak_days integer DEFAULT 0,
    best_streak integer DEFAULT 0,
    last_activity_date date,
    authority_score numeric(8,2) DEFAULT 0,
    authority_tier text DEFAULT 'reader'::text,
    content_quality_avg numeric(4,2) DEFAULT 0,
    citations_received integer DEFAULT 0,
    mentorship_score integer DEFAULT 0,
    expertise_tags text[] DEFAULT '{}'::text[],
    can_create_articles boolean DEFAULT false,
    can_boost_topics boolean DEFAULT false,
    authority_updated_at timestamp with time zone DEFAULT now(),
    last_active_at timestamp with time zone DEFAULT now(),
    posts_created integer DEFAULT 0,
    topics_created integer DEFAULT 0,
    reputation_score integer DEFAULT 0
);

ALTER TABLE ONLY public.forum_user_stats REPLICA IDENTITY FULL;


--
-- Name: forum_warning_appeals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_warning_appeals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warning_id uuid,
    user_id uuid,
    reason text NOT NULL,
    status text DEFAULT 'pending'::text,
    moderator_id uuid,
    resolution text,
    created_at timestamp with time zone DEFAULT now(),
    resolved_at timestamp with time zone
);


--
-- Name: forum_warning_points; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_warning_points (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    points integer DEFAULT 0,
    reason text,
    issued_by uuid,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: forum_warnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forum_warnings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    moderator_id uuid,
    reason text NOT NULL,
    severity text DEFAULT 'warning'::text,
    points integer DEFAULT 1,
    expires_at timestamp with time zone,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: gallery_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gallery_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type text DEFAULT 'image'::text,
    title text,
    description text,
    url text,
    thumbnail_url text,
    prompt text,
    style text,
    track_id uuid,
    is_public boolean DEFAULT false,
    likes_count integer DEFAULT 0,
    views_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: gallery_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gallery_likes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gallery_item_id uuid,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: generated_lyrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generated_lyrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    prompt text,
    lyrics text,
    title text,
    genre text,
    mood text,
    language text DEFAULT 'ru'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: generation_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generation_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    model text,
    prompt text,
    status text DEFAULT 'pending'::text,
    cost_rub integer DEFAULT 0,
    duration_ms integer,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: generation_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generation_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type text DEFAULT 'music'::text,
    prompt text,
    settings jsonb DEFAULT '{}'::jsonb,
    status text DEFAULT 'queued'::text,
    "position" integer DEFAULT 0,
    priority integer DEFAULT 0,
    track_id uuid,
    error_message text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: genre_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genre_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    name_ru text NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: genres; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genres (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid NOT NULL,
    name text NOT NULL,
    name_ru text NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: impersonation_action_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.impersonation_action_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin_id uuid,
    target_user_id uuid,
    action text,
    details jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: internal_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.internal_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    vote text,
    comment text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: item_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_purchases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid,
    buyer_id uuid,
    seller_id uuid,
    price integer DEFAULT 0,
    status text DEFAULT 'completed'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: legal_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    content text,
    version text,
    is_active boolean DEFAULT true,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: lyrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lyrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text,
    content text NOT NULL,
    genre text,
    mood text,
    language text DEFAULT 'ru'::text,
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: lyrics_deposits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lyrics_deposits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    lyrics_item_id uuid,
    amount integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: lyrics_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lyrics_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text,
    content text,
    genre text,
    mood text,
    tags text[],
    price integer DEFAULT 0,
    is_public boolean DEFAULT false,
    downloads_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    description text,
    genre_id uuid,
    is_active boolean DEFAULT true,
    is_exclusive boolean DEFAULT false,
    is_for_sale boolean DEFAULT false,
    language text,
    license_type text,
    sales_count integer DEFAULT 0,
    track_id uuid,
    views_count integer DEFAULT 0
);


--
-- Name: maintenance_whitelist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.maintenance_whitelist (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: message_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid,
    user_id uuid,
    emoji text NOT NULL,
    conversation_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sender_id uuid,
    receiver_id uuid,
    content text,
    attachment_url text,
    is_read boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    conversation_id uuid,
    attachment_type text,
    forwarded_from_id uuid,
    deleted_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: moderator_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderator_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    category_id uuid,
    can_edit boolean DEFAULT false,
    can_delete boolean DEFAULT false,
    can_ban boolean DEFAULT false,
    granted_by uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: moderator_presets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderator_presets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    permissions jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    name_ru text,
    description text,
    category_ids uuid[] DEFAULT ARRAY[]::uuid[],
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type text NOT NULL,
    title text,
    message text,
    data jsonb DEFAULT '{}'::jsonb,
    is_read boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    actor_id uuid,
    link text,
    metadata jsonb DEFAULT '{}'::jsonb,
    target_id uuid,
    target_type text
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    amount numeric NOT NULL,
    currency text DEFAULT 'RUB'::text,
    status text DEFAULT 'pending'::text,
    provider text,
    provider_payment_id text,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    external_id text,
    payment_system text
);


--
-- Name: payout_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payout_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    seller_id uuid,
    amount numeric NOT NULL,
    payment_method text,
    payment_details text,
    status text DEFAULT 'pending'::text,
    processed_at timestamp with time zone,
    processed_by uuid,
    notes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: performance_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.performance_alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    metric text,
    value numeric,
    threshold numeric,
    severity text DEFAULT 'warning'::text,
    context jsonb DEFAULT '{}'::jsonb,
    resolved boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: permission_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permission_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    description text,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    key text,
    name_ru text,
    is_active boolean DEFAULT true,
    icon text
);


--
-- Name: personas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    name text NOT NULL,
    description text,
    avatar_url text,
    voice_style text,
    settings jsonb DEFAULT '{}'::jsonb,
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: playlist_tracks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.playlist_tracks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    playlist_id uuid,
    track_id uuid,
    "position" integer DEFAULT 0,
    added_at timestamp with time zone DEFAULT now()
);


--
-- Name: playlists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.playlists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text NOT NULL,
    description text,
    cover_url text,
    is_public boolean DEFAULT true,
    tracks_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    likes_count integer DEFAULT 0,
    plays_count integer DEFAULT 0
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    username text,
    avatar_url text,
    balance integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    display_name text,
    role text DEFAULT 'user'::text,
    is_super_admin boolean DEFAULT false,
    is_protected boolean DEFAULT false,
    bio text,
    subscription_type text DEFAULT 'free'::text,
    subscription_expires_at timestamp with time zone,
    email text,
    generation_count integer DEFAULT 0,
    total_likes integer DEFAULT 0,
    followers_count integer DEFAULT 0,
    following_count integer DEFAULT 0,
    tracks_count integer DEFAULT 0,
    is_verified boolean DEFAULT false,
    onboarding_completed boolean DEFAULT false,
    ad_free_until timestamp with time zone,
    is_blocked boolean DEFAULT false,
    blocked_at timestamp with time zone,
    blocked_reason text,
    blocked_by uuid,
    referral_code text,
    referred_by uuid,
    cover_url text,
    social_links jsonb DEFAULT '{}'::jsonb,
    notification_settings jsonb DEFAULT '{}'::jsonb,
    email_unsubscribed boolean DEFAULT false,
    short_id text,
    last_seen_at timestamp with time zone,
    xp integer DEFAULT 0,
    level integer DEFAULT 1,
    trust_level integer DEFAULT 0,
    specialty text DEFAULT ''::text,
    ad_free_purchased_at timestamp with time zone,
    contest_participations integer DEFAULT 0,
    contest_wins jsonb DEFAULT '[]'::jsonb,
    contest_wins_count integer DEFAULT 0,
    email_last_changed_at timestamp with time zone,
    total_prize_won numeric DEFAULT 0,
    verification_type text,
    verified_at timestamp with time zone,
    verified_by uuid,
    credits integer DEFAULT 0,
    contests_entered integer DEFAULT 0 NOT NULL,
    contests_won integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.profiles REPLICA IDENTITY FULL;


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    role public.app_role NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: profiles_public; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.profiles_public WITH (security_invoker='on') AS
 SELECT p.id,
    p.user_id,
    p.username,
    p.avatar_url,
    p.cover_url,
    p.bio,
    p.social_links,
    p.followers_count,
    p.following_count,
    p.last_seen_at,
    p.created_at,
    p.updated_at
   FROM public.profiles p
  WHERE (public.is_admin(auth.uid()) OR (NOT (EXISTS ( SELECT 1
           FROM public.user_roles ur
          WHERE ((ur.user_id = p.user_id) AND (ur.role = 'super_admin'::public.app_role))))));


--
-- Name: promo_videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.promo_videos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    title text,
    video_url text,
    thumbnail_url text,
    status text DEFAULT 'pending'::text,
    is_public boolean DEFAULT false,
    views_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: prompt_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompt_purchases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    buyer_id uuid,
    prompt_id uuid,
    seller_id uuid,
    price integer DEFAULT 0,
    payment_id uuid,
    status text DEFAULT 'completed'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: prompts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text NOT NULL,
    description text,
    prompt_text text NOT NULL,
    genre text,
    tags text[],
    price integer DEFAULT 0,
    is_public boolean DEFAULT false,
    uses_count integer DEFAULT 0,
    rating numeric DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_bounties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_bounties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    category text,
    severity_min text DEFAULT 'minor'::text,
    reward_xp integer DEFAULT 0,
    reward_credits integer DEFAULT 0,
    max_claims integer DEFAULT 10,
    claimed_count integer DEFAULT 0,
    is_active boolean DEFAULT true,
    expires_at timestamp with time zone,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_id uuid NOT NULL,
    user_id uuid NOT NULL,
    message text NOT NULL,
    is_staff boolean DEFAULT false,
    is_system boolean DEFAULT false,
    attachments jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_config (
    key text NOT NULL,
    value jsonb NOT NULL,
    label text,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_tester_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_tester_stats (
    user_id uuid NOT NULL,
    tier text DEFAULT 'contributor'::text,
    reports_total integer DEFAULT 0,
    reports_confirmed integer DEFAULT 0,
    reports_rejected integer DEFAULT 0,
    reports_critical integer DEFAULT 0,
    votes_cast integer DEFAULT 0,
    accuracy_rate numeric DEFAULT 0,
    xp_earned integer DEFAULT 0,
    credits_earned integer DEFAULT 0,
    streak_days integer DEFAULT 0,
    best_streak integer DEFAULT 0,
    last_report_at timestamp with time zone,
    tier_updated_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_number text,
    reporter_id uuid NOT NULL,
    category text DEFAULT 'ui'::text NOT NULL,
    severity text DEFAULT 'minor'::text NOT NULL,
    status text DEFAULT 'new'::text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    steps_to_reproduce text,
    expected_behavior text,
    actual_behavior text,
    page_url text,
    user_agent text,
    browser_info jsonb DEFAULT '{}'::jsonb,
    screenshots jsonb DEFAULT '[]'::jsonb,
    duplicate_of uuid,
    is_verified boolean DEFAULT false,
    verified_by uuid,
    verified_at timestamp with time zone,
    verification_count integer DEFAULT 0,
    assigned_to uuid,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    resolution_notes text,
    reward_xp integer DEFAULT 0,
    reward_credits integer DEFAULT 0,
    bounty_id uuid,
    upvotes integer DEFAULT 0,
    priority_score numeric DEFAULT 0,
    tags text[] DEFAULT '{}'::text[],
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: qa_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qa_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_id uuid NOT NULL,
    user_id uuid NOT NULL,
    vote_type text DEFAULT 'confirm'::text NOT NULL,
    voter_weight numeric DEFAULT 1.0,
    comment text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_ad_placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_ad_placements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    advertiser_name text,
    ad_type text DEFAULT 'audio_insert'::text,
    audio_url text,
    promo_text text,
    price_paid numeric DEFAULT 0,
    impressions integer DEFAULT 0,
    clicks integer DEFAULT 0,
    starts_at timestamp with time zone DEFAULT now(),
    ends_at timestamp with time zone,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_bids; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_bids (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slot_id uuid NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    amount numeric DEFAULT 0 NOT NULL,
    status text DEFAULT 'active'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_config (
    key text NOT NULL,
    value jsonb DEFAULT '{}'::jsonb NOT NULL,
    label text,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_listens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_listens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    session_id text,
    listen_duration_sec integer DEFAULT 0,
    track_duration_sec integer DEFAULT 0,
    listen_percent numeric DEFAULT 0,
    xp_earned integer DEFAULT 0,
    reaction text,
    is_afk_verified boolean DEFAULT false,
    afk_response_ms integer,
    ip_hash text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_predictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_predictions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    bet_amount numeric DEFAULT 0 NOT NULL,
    predicted_hit boolean DEFAULT true NOT NULL,
    actual_result boolean,
    payout numeric DEFAULT 0,
    status text DEFAULT 'pending'::text,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    user_id uuid,
    source text DEFAULT 'algorithm'::text NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    chance_score numeric DEFAULT 0,
    quality_component numeric DEFAULT 0,
    xp_component numeric DEFAULT 0,
    stake_component numeric DEFAULT 0,
    freshness_component numeric DEFAULT 0,
    discovery_component numeric DEFAULT 0,
    played_at timestamp with time zone,
    is_played boolean DEFAULT false,
    genre_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: radio_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slot_number integer NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    status text DEFAULT 'open'::text,
    winner_user_id uuid,
    winner_track_id uuid,
    winning_bid numeric DEFAULT 0,
    total_bids integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: referral_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referral_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    code text NOT NULL,
    uses_count integer DEFAULT 0,
    max_uses integer,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: referral_rewards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referral_rewards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    referral_id uuid,
    user_id uuid,
    type text DEFAULT 'bonus'::text,
    amount integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: referral_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referral_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: referral_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referral_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    total_referrals integer DEFAULT 0,
    active_referrals integer DEFAULT 0,
    total_earned integer DEFAULT 0,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referrals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    referrer_id uuid,
    referred_id uuid,
    bonus_amount integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: reputation_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reputation_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type text NOT NULL,
    xp_delta integer DEFAULT 0,
    reputation_delta integer DEFAULT 0,
    category text DEFAULT 'general'::text NOT NULL,
    source_type text,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reputation_events_category_check CHECK ((category = ANY (ARRAY['forum'::text, 'music'::text, 'social'::text, 'contest'::text, 'creator'::text, 'general'::text])))
);


--
-- Name: reputation_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reputation_tiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    name_ru text NOT NULL,
    name_en text NOT NULL,
    level integer NOT NULL,
    min_xp integer DEFAULT 0 NOT NULL,
    icon text DEFAULT '🎵'::text NOT NULL,
    color text DEFAULT '#888888'::text NOT NULL,
    gradient text,
    vote_weight numeric(3,2) DEFAULT 1.0 NOT NULL,
    perks jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    marketplace_commission numeric(4,3) DEFAULT 0.15,
    attribution_multiplier numeric(3,2) DEFAULT 0,
    bonus_generations integer DEFAULT 0,
    feed_boost numeric(3,2) DEFAULT 1.0,
    can_sell_premium boolean DEFAULT false,
    can_create_voice_print boolean DEFAULT false
);


--
-- Name: role_change_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_change_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    changed_by uuid,
    action text,
    reason text,
    metadata jsonb,
    old_role text,
    new_role text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT role_change_logs_action_check CHECK ((action = ANY (ARRAY['invited'::text, 'accepted'::text, 'declined'::text, 'revoked'::text, 'expired'::text, 'assigned'::text, 'blocked'::text, 'unblocked'::text, 'invitation_cancelled'::text, 'user_deleted'::text, 'moderation_sent_to_voting'::text, 'balance_changed'::text, 'moderation_approved'::text])))
);


--
-- Name: role_invitation_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_invitation_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invitation_id uuid,
    category_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: role_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    role text NOT NULL,
    status text DEFAULT 'pending'::text,
    invited_by uuid,
    expires_at timestamp with time zone DEFAULT (now() + '7 days'::interval),
    created_at timestamp with time zone DEFAULT now(),
    message text,
    responded_at timestamp with time zone,
    CONSTRAINT role_invitations_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'declined'::text, 'expired'::text, 'cancelled'::text])))
);


--
-- Name: security_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.security_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text,
    ip_address text,
    user_agent text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: seller_earnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_earnings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    source_type text,
    source_id uuid,
    amount numeric DEFAULT 0,
    platform_fee numeric DEFAULT 0,
    net_amount numeric DEFAULT 0,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value text,
    updated_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    description text
);


--
-- Name: store_beats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.store_beats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    title text,
    description text,
    price integer DEFAULT 0,
    license_type text DEFAULT 'basic'::text,
    is_active boolean DEFAULT true,
    sales_count integer DEFAULT 0,
    tags text[],
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: store_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.store_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type text DEFAULT 'digital'::text,
    title text NOT NULL,
    description text,
    price integer DEFAULT 0,
    cover_url text,
    file_url text,
    category text,
    tags text[],
    is_active boolean DEFAULT true,
    sales_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    genre_id uuid,
    is_exclusive boolean DEFAULT false,
    item_type text,
    license_terms text,
    license_type text,
    preview_url text,
    seller_id uuid,
    source_id uuid,
    views_count integer DEFAULT 0
);


--
-- Name: subscription_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    name_ru text,
    description text,
    price_monthly integer DEFAULT 0,
    price_yearly integer DEFAULT 0,
    features jsonb DEFAULT '[]'::jsonb,
    daily_generations integer DEFAULT 5,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    badge_emoji text,
    commercial_license boolean DEFAULT false,
    generation_credits integer DEFAULT 0,
    no_watermark boolean DEFAULT false,
    priority_generation boolean DEFAULT false,
    service_quotas jsonb DEFAULT '{}'::jsonb,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: support_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_id uuid,
    user_id uuid,
    message text NOT NULL,
    is_staff boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: support_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    subject text NOT NULL,
    message text NOT NULL,
    status text DEFAULT 'open'::text,
    priority text DEFAULT 'normal'::text,
    category text,
    assigned_to uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: system_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value jsonb DEFAULT '{}'::jsonb,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    prompt_template text,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ticket_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_id uuid,
    user_id uuid,
    message text NOT NULL,
    is_staff boolean DEFAULT false,
    attachment_url text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_addons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_addons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    addon_service_id uuid,
    status text DEFAULT 'pending'::text,
    result_url text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_bookmarks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: track_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    content text NOT NULL,
    parent_id uuid,
    likes_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    is_pinned boolean DEFAULT false,
    is_hidden boolean DEFAULT false,
    timestamp_seconds integer,
    quote_text text,
    quote_author text
);


--
-- Name: track_daily_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_daily_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    date date DEFAULT CURRENT_DATE NOT NULL,
    plays integer DEFAULT 0,
    likes integer DEFAULT 0,
    downloads integer DEFAULT 0,
    shares integer DEFAULT 0,
    comments integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_deposits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_deposits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    track_id uuid,
    amount integer DEFAULT 0,
    status text DEFAULT 'pending'::text,
    payment_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    method text,
    completed_at timestamp with time zone,
    file_hash text NOT NULL,
    metadata_hash text,
    certificate_url text,
    blockchain_tx_id text,
    external_deposit_id text,
    external_certificate_url text,
    error_message text,
    performer_name text,
    lyrics_author text
);


--
-- Name: track_feed_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_feed_scores (
    track_id uuid NOT NULL,
    raw_engagement numeric DEFAULT 0,
    weighted_engagement numeric DEFAULT 0,
    velocity_1h numeric DEFAULT 0,
    velocity_24h numeric DEFAULT 0,
    time_decay_factor numeric DEFAULT 1.0,
    final_score numeric DEFAULT 0,
    stream_eligible text[] DEFAULT '{}'::text[],
    is_spam boolean DEFAULT false,
    calculated_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_health_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_health_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    check_type text,
    status text DEFAULT 'ok'::text,
    details jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_likes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: track_promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_promotions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    type text DEFAULT 'boost'::text,
    status text DEFAULT 'active'::text,
    amount integer DEFAULT 0,
    impressions integer DEFAULT 0,
    clicks integer DEFAULT 0,
    starts_at timestamp with time zone DEFAULT now(),
    ends_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    expires_at timestamp with time zone,
    boost_type text DEFAULT 'standard'::text
);


--
-- Name: track_quality_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_quality_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    user_id uuid NOT NULL,
    engagement_rate numeric(6,4) DEFAULT 0,
    completion_rate numeric(6,4) DEFAULT 0,
    unique_listeners_48h integer DEFAULT 0,
    save_rate numeric(6,4) DEFAULT 0,
    skip_rate numeric(6,4) DEFAULT 0,
    replay_rate numeric(6,4) DEFAULT 0,
    quality_score numeric(4,2) DEFAULT 0,
    eligible_for_feed boolean DEFAULT true,
    eligible_for_attribution boolean DEFAULT true,
    flagged_as_spam boolean DEFAULT false,
    metrics_collected_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT track_quality_scores_quality_score_check CHECK (((quality_score >= (0)::numeric) AND (quality_score <= (10)::numeric)))
);


--
-- Name: track_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    user_id uuid NOT NULL,
    reaction_type text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: track_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    reporter_id uuid,
    reason text NOT NULL,
    status text DEFAULT 'pending'::text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: track_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.track_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid,
    user_id uuid,
    vote_type text DEFAULT 'like'::text,
    created_at timestamp with time zone DEFAULT now(),
    comment text
);


--
-- Name: user_achievements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_achievements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    achievement_id uuid,
    unlocked_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_blocks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    blocked_by uuid,
    reason text,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_challenges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    challenge_id uuid,
    progress integer DEFAULT 0,
    completed boolean DEFAULT false,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_follows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    follower_id uuid,
    following_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_prompts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_prompts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text NOT NULL,
    description text,
    prompt_text text DEFAULT ''::text,
    genre text,
    tags text[],
    price integer DEFAULT 0,
    is_public boolean DEFAULT false,
    downloads_count integer DEFAULT 0,
    rating numeric DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    lyrics text,
    genre_id text,
    vocal_type_id text,
    template_id text,
    artist_style_id text,
    uses_count integer DEFAULT 0,
    track_id uuid,
    is_exclusive boolean DEFAULT false,
    license_type text
);


--
-- Name: user_streaks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_streaks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    current_streak integer DEFAULT 0,
    longest_streak integer DEFAULT 0,
    last_activity_date date,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    plan_id uuid,
    status text DEFAULT 'active'::text,
    period_type text DEFAULT 'monthly'::text,
    current_period_start timestamp with time zone DEFAULT now(),
    current_period_end timestamp with time zone,
    canceled_at timestamp with time zone,
    payment_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: verification_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verification_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type text DEFAULT 'artist'::text,
    status text DEFAULT 'pending'::text,
    real_name text,
    social_links jsonb DEFAULT '[]'::jsonb,
    documents jsonb DEFAULT '[]'::jsonb,
    notes text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    rejection_reason text
);


--
-- Name: vocal_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vocal_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    name_ru text NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: xp_event_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.xp_event_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type text NOT NULL,
    xp_amount integer DEFAULT 0 NOT NULL,
    reputation_amount integer DEFAULT 0 NOT NULL,
    category text DEFAULT 'general'::text NOT NULL,
    cooldown_minutes integer DEFAULT 0,
    daily_limit integer DEFAULT 0,
    requires_quality_check boolean DEFAULT false,
    description text,
    is_active boolean DEFAULT true
);


--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.users (id, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at, last_sign_in_at, is_super_admin) FROM stdin;
a0000000-0000-0000-0000-000000000001	romzett@mail.ru	$2a$10$xvxUl.RbTl/gbcwrQVjLn.5slqEqZn24TK/1zWy5PoFBMFWyPDYr6	2026-02-13 12:06:38.837303+00	{"role": "superadmin", "display_name": "AI Planet Sound"}	2026-02-13 12:06:38.837303+00	2026-02-13 12:06:38.837303+00	2026-02-15 15:02:04.507773+00	t
577de5d6-c06e-4583-9631-9817db23b84d	shvedov@bk.ru	$2a$10$RngqunS4ddDHdM3kh.9SOOid0TuvVrHDremBhAh7FkbC9ZSatWloa	2026-02-15 21:57:45.755371+00	{"username": "Swede"}	2026-02-15 21:56:54.572679+00	2026-02-15 21:57:45.755371+00	2026-02-15 21:58:00.629879+00	f
955ff6c1-f3db-4087-8e68-cb67ffc41862	shvedov.roman@mail.ru	$2a$10$0i6NIbeqTMvkfsiOxbbjOe3IB17mvqV3b.uug1F562DNQsN9sgaFC	2026-02-14 19:12:54.844881+00	{"username": "Страдалец"}	2026-02-14 19:12:09.051637+00	2026-02-14 19:12:54.844881+00	2026-02-15 22:14:42.126352+00	f
fe67116b-0ad9-4491-9670-f40d1939db1e	vladavershininaavtor@yandex.ru	$2a$10$1p67VD91nHCYi3nFyewJBOPZZUXQ40Z9/mxggY4GBa6lMov886I.a	2026-02-15 17:06:26.54321+00	{"username": "Золотинка"}	2026-02-15 17:06:03.798788+00	2026-02-15 17:06:26.54321+00	2026-02-16 21:27:06.962937+00	f
\.


--
-- Data for Name: achievements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.achievements (id, name, name_ru, description, icon, category, xp_reward, condition_type, condition_value, is_active, created_at, key, description_ru, rarity, requirement_type, requirement_value, credit_reward, sort_order) FROM stdin;
6cc1aa0b-fa0c-440e-a2c0-2f0bf801e245	First Post	Первый пост	Write your first forum post	✍️	forum	10	\N	0	t	2026-02-14 11:05:39.060627+00	first_post	Напишите первый пост на форуме	common	posts_created	1	0	10
73137f97-306c-4a94-a8a4-9a1b1db71d26	Topic Starter	Автор тем	Create 10 forum topics	📝	forum	25	\N	0	t	2026-02-14 11:05:39.060627+00	topic_starter	Создайте 10 тем на форуме	common	topics_created	10	5	11
091ea19d-c1e6-4de3-916c-076290167ea2	Helpful Answer	Полезный ответ	Get 5 solutions marked	💡	forum	50	\N	0	t	2026-02-14 11:05:39.060627+00	helpful_answer	Получите 5 отметок «решение»	rare	solutions_count	5	10	12
caeba5e1-23c7-4135-9d34-c0c02cf85d8a	Forum Guru	Гуру форума	Reach 100 posts	🧠	forum	100	\N	0	t	2026-02-14 11:05:39.060627+00	forum_guru	Напишите 100 постов	epic	posts_created	100	25	13
880c3f8e-4c01-4f4e-8dbc-77473852a093	Knowledge Keeper	Хранитель знаний	Create 5 guides	📚	creator	150	\N	0	t	2026-02-14 11:05:39.060627+00	knowledge_keeper	Создайте 5 гайдов	epic	guides_published	5	50	14
bc142d0c-8f00-4928-ae74-c53b98a39b11	First Track	Первый трек	Generate your first track	🎵	music	10	\N	0	t	2026-02-14 11:05:39.060627+00	first_track	Сгенерируйте свой первый трек	common	tracks_published	1	0	20
2604333f-1f66-4218-9c1d-177bd1a2a5ce	Prolific Creator	Плодовитый автор	Publish 25 tracks	🎶	music	50	\N	0	t	2026-02-14 11:05:39.060627+00	prolific_creator	Опубликуйте 25 треков	common	tracks_published	25	10	21
d4088160-a7ff-4a6c-a356-223ec8ec00b4	Hit Maker	Хитмейкер	Get 100 likes on tracks	🔥	music	100	\N	0	t	2026-02-14 11:05:39.060627+00	hit_maker	Получите 100 лайков на треки	rare	tracks_liked_received	100	25	22
4186103d-3f8f-483d-9f4f-f543019980a0	Chart Topper	Топ чартов	Get 500 likes on tracks	🏆	music	200	\N	0	t	2026-02-14 11:05:39.060627+00	chart_topper	Получите 500 лайков на треки	epic	tracks_liked_received	500	50	23
4f46dd33-a88d-4cd3-b1a7-5892b54472d7	Sound Pioneer	Пионер звука	Publish 100 tracks	🚀	music	300	\N	0	t	2026-02-14 11:05:39.060627+00	sound_pioneer	Опубликуйте 100 треков	legendary	tracks_published	100	100	24
68e8d345-ba57-464d-a803-cda76ab52ae5	Social Butterfly	Социальная бабочка	Get 10 followers	🦋	social	20	\N	0	t	2026-02-14 11:05:39.060627+00	social_butterfly	Получите 10 подписчиков	common	followers_count	10	5	30
354c9d42-8036-4b16-981f-f8b6a0e448a3	Influencer	Инфлюенсер	Get 50 followers	⭐	social	75	\N	0	t	2026-02-14 11:05:39.060627+00	influencer	Получите 50 подписчиков	rare	followers_count	50	20	31
5a85bd2b-1cc6-4116-89e6-14e392ce4810	Community Pillar	Опора сообщества	Get 200 followers	🏛️	social	150	\N	0	t	2026-02-14 11:05:39.060627+00	community_pillar	Получите 200 подписчиков	epic	followers_count	200	50	32
55ea0f72-120c-422b-ab98-be4bb439704a	Collaborator	Коллаборант	Complete 5 collaborations	🤝	social	100	\N	0	t	2026-02-14 11:05:39.060627+00	collaborator	Завершите 5 коллабораций	rare	collaborations_count	5	30	33
45700c5f-7829-425d-9fa8-f1e1eedb9f24	Arena Debut	Дебют на арене	Enter first contest	⚔️	contest	15	\N	0	t	2026-02-14 11:05:39.060627+00	arena_debut	Примите участие в первом конкурсе	common	contests_entered	1	0	40
05bc94c7-1d96-4782-829d-3ed0922339f1	Arena Champion	Чемпион арены	Win 3 contests	🥇	contest	200	\N	0	t	2026-02-14 11:05:39.060627+00	arena_champion	Победите в 3 конкурсах	epic	contests_won	3	75	41
73fecedd-78a7-453a-8382-dc17fd3a94fc	Streak Fire	Серия огня	7-day contest streak	🔥	contest	75	\N	0	t	2026-02-14 11:05:39.060627+00	streak_fire	Серия участия 7 дней подряд	rare	streak_days	7	20	42
edee8e40-e838-4132-a223-a8d30f665da8	Early Adopter	Ранний пользователь	Joined during beta	🌟	general	100	\N	0	t	2026-02-14 11:05:39.060627+00	early_adopter	Зарегистрировались в бета-периоде	legendary	manual	1	50	50
4fb4a3ae-a20d-4ab2-a173-510a019c7609	Daily Devotion	Ежедневная преданность	30-day streak	📅	general	200	\N	0	t	2026-02-14 11:05:39.060627+00	daily_devotion	Серия активности 30 дней подряд	epic	streak_days	30	75	51
ee1c37d0-eeb4-4159-a738-99719e3ac63c	Legend	Легенда	Reach AI Maestro tier	👑	general	500	\N	0	t	2026-02-14 11:05:39.060627+00	legend	Достигните звания ИИ-Маэстро	legendary	tier_reached	4	200	52
\.


--
-- Data for Name: ad_campaign_slots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_campaign_slots (id, campaign_id, slot_id, priority, created_at, is_active, priority_override) FROM stdin;
\.


--
-- Data for Name: ad_campaigns; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_campaigns (id, name, slot_key, status, budget, spent, impressions, clicks, image_url, link_url, html_content, start_date, end_date, targeting, created_at, updated_at, description, advertiser_name, advertiser_url, campaign_type, internal_type, internal_id, budget_daily, budget_total, impressions_count, clicks_count, priority, created_by) FROM stdin;
\.


--
-- Data for Name: ad_creatives; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_creatives (id, campaign_id, type, title, description, media_url, click_url, cta_text, is_active, created_at, updated_at, creative_type, subtitle, media_type, thumbnail_url, external_video_url, variant, width, height, aspect_ratio) FROM stdin;
\.


--
-- Data for Name: ad_impressions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_impressions (id, campaign_id, creative_id, slot_id, user_id, ip_address, is_click, metadata, created_at, device_type, page_url, viewed_at, view_duration_ms, clicked_at, session_id) FROM stdin;
\.


--
-- Data for Name: ad_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_settings (id, key, value, created_at, updated_at, description) FROM stdin;
6ac3cc77-5470-4859-96c0-5b42c421ddfb	ads_enabled	false	2026-02-13 16:06:28.541764+00	2026-02-14 00:14:27.02+00	Р’РєР»СЋС‡РёС‚СЊ СЂРµРєР»Р°РјСѓ РіР»РѕР±Р°Р»СЊРЅРѕ
1bada62d-af6a-4eea-b6ad-2bc892eae486	max_ads_per_hour	20	2026-02-14 00:26:47.401917+00	2026-02-14 00:26:47.401917+00	Макс. показов рекламы пользователю за час (серверная проверка)
\.


--
-- Data for Name: ad_slots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_slots (id, name, slot_type, description, width, height, is_active, base_price, created_at, slot_key, is_enabled, max_ads, recommended_width, recommended_height, recommended_aspect_ratio, supported_types, frequency_cap, cooldown_seconds, updated_at) FROM stdin;
7860317a-4f9c-44bc-906e-de1e778717da	Баннер ленты	feed_banner	Баннер в ленте треков	\N	\N	t	0	2026-02-14 00:29:09.731372+00	feed_banner	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
3f2d632e-e82a-43f9-bb9d-b69b5720770c	Баннер сайдбара	sidebar_banner	Баннер в боковой панели	\N	\N	t	0	2026-02-14 00:29:09.731372+00	sidebar_banner	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
5be724b6-0dce-4cdf-8b34-ba3865756682	Hero баннер	hero_banner	Главный баннер на главной	\N	\N	t	0	2026-02-14 00:29:09.731372+00	hero_banner	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
f7e052da-c7bb-4fb4-8a5f-0b6b674c0be6	Между генерациями	between_generations	Полноэкранная реклама после генерации	\N	\N	t	0	2026-02-14 00:29:09.731372+00	between_generations	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
bea6eda1-8f95-4037-bc6b-5668e4be2154	Баннер форума (лента)	forum_feed	Баннер в ленте форума	\N	\N	t	0	2026-02-14 00:29:09.731372+00	forum_feed	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
714c0ae6-1f24-4afd-8c12-fcab6da0843a	Баннер форума (сайдбар)	forum_sidebar	Баннер в сайдбаре форума	\N	\N	t	0	2026-02-14 00:29:09.731372+00	forum_sidebar	t	1	\N	\N	\N	\N	10	60	2026-02-14 00:29:09.731372+00
\.


--
-- Data for Name: ad_targeting; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ad_targeting (id, campaign_id, target_type, target_value, created_at, target_free_users, target_subscribed_users, target_mobile, target_desktop, min_generations, max_generations, min_days_registered, show_hours_start, show_hours_end, show_days_of_week, updated_at) FROM stdin;
\.


--
-- Data for Name: addon_services; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.addon_services (id, name, name_ru, description, description_ru, price_rub, is_active, sort_order, category, icon, created_at, price_aipci, updated_at) FROM stdin;
d4db7a17-cd18-499b-8dbb-23e1f32de25f	analyze_lyrics	AI Разметка текста	AI анализ и разметка текста песни с определением жанра, настроения и стиля	\N	5	t	13	audio	brain	2026-01-24 19:31:52.888805+00	0	2026-02-08 13:18:15.704885+00
5746c214-e62e-47a2-8923-66036ee13aee	generate_lyrics	Сгенерировать текст	AI генерация текста песни по вашему описанию	\N	5	t	11	audio	text	2026-01-17 19:25:17.063531+00	0	2026-02-11 01:29:46.642352+00
44a9e8c0-e9d8-4b38-a16c-e96234a25f76	boost_style	Boost стиль музыки	Улучшение и детализация описания стиля для модели V4.5	\N	5	t	12	audio	sparkles	2026-01-17 19:25:17.063531+00	0	2026-02-11 01:29:47.456315+00
2b4b83a6-24a8-4e32-9c33-e59ff4974ba7	timestamped_lyrics	Текст с таймкодами	Получение текста с временными метками для караоке	\N	5	t	14	audio	clock	2026-01-17 19:25:17.063531+00	0	2026-02-08 13:18:15.704885+00
2b775702-e716-435f-b70b-62da14d92359	vocal_separation	Разделение вокала	Отделение вокала от инструментов	\N	20	t	20	audio	mic	2026-01-17 14:06:10.600622+00	0	2026-02-08 13:18:15.704885+00
50562a67-efc8-43fe-bf1f-786ce91b5592	create_prompt	Создать промпт	Создание профессионального промпта по описанию на русском языке	\N	5	t	10	audio	sparkles	2026-01-22 15:56:10.443583+00	0	2026-02-08 13:18:15.704885+00
1864e766-fddc-45cb-b899-258f8312ce0d	stem_separation	Разделение дорожек	Разделение на отдельные инструменты (drums, bass, guitar, piano)	\N	150	t	21	audio	layers	2026-01-17 14:06:10.600622+00	0	2026-02-08 13:18:15.704885+00
d7e0d125-04f6-4c43-b46f-c0c335ac31ab	add_vocal	Добавить вокал	Добавление вокала к инструментальному треку с помощью AI	\N	15	t	22	audio	mic	2026-01-20 21:31:59.686494+00	0	2026-02-08 13:18:15.704885+00
5fd8f4e0-6c6d-47cb-bfd4-0ffb5f744bbb	convert_wav	Конвертировать в WAV	Конвертация трека в lossless WAV формат высокого качества	\N	5	t	23	audio	download	2026-01-17 19:25:17.063531+00	0	2026-02-08 13:18:15.704885+00
508c7c4f-cea3-4ecb-a87d-67f64a355163	ringtone	Рингтон	Оптимизированная версия для звонка (30 сек)	\N	5	t	24	audio	bell	2026-01-17 13:28:49.482599+00	0	2026-02-08 13:18:15.704885+00
c51ce560-2abd-4068-abe3-0ff4b9c066b6	large_cover	HD обложка	Большая обложка высокого разрешения (1920x1920)	\N	10	t	30	audio	image	2026-01-17 13:28:49.482599+00	0	2026-02-08 13:18:15.704885+00
46b42d87-7532-43c1-b96e-2c0a0577a635	upload_cover	Создать кавер	Создание AI кавер-версии загруженного аудио файла	\N	15	t	31	audio	music	2026-01-20 21:23:31.283804+00	0	2026-02-08 13:18:15.704885+00
32d81867-bf87-421b-b40f-3aebcdf8a6a1	short_video	Музыкальное видео	Генерация MP4 музыкального видео через Suno API	\N	25	t	32	audio	video	2026-01-17 13:28:49.482599+00	0	2026-02-08 13:18:15.704885+00
df0d0676-3032-47f8-9f20-c4df45a2985c	boost_track_1h	Буст трека (1 час)	Поднять трек в ленте на 1 час	\N	10	t	40	audio	rocket	2026-01-24 16:10:14.10604+00	0	2026-02-08 13:18:15.704885+00
cfa70eb2-1c58-46c1-9db6-7c45a6ba5292	boost_track_6h	Буст трека (6 часов)	Поднять трек в ленте на 6 часов	\N	40	t	41	audio	rocket	2026-01-24 16:10:14.10604+00	0	2026-02-08 13:18:15.704885+00
a5b4ae11-3b48-48dd-87b0-8a193769440b	boost_track_24h	Буст трека (24 часа)	Поднять трек в ленте на сутки	\N	100	t	42	audio	rocket	2026-01-24 16:10:14.10604+00	0	2026-02-08 13:18:15.704885+00
d1ff251e-e8b5-48dc-82ca-53a920147ebe	forum_expand_reply	Развернуть ответ	AI развёртывает тезисы пользователя в полноценный ответ на тему	\N	5	t	50	audio	sparkles	2026-02-08 11:35:33.748838+00	0	2026-02-08 13:18:15.704885+00
c00c7ae8-b483-4cd6-9cbc-ba7a6e2d3837	forum_spell_check	Проверка орфографии (форум)	AI-проверка орфографии и грамматики в постах форума через DeepSeek	\N	3	t	52	audio	SpellCheck	2026-02-08 11:10:02.780257+00	0	2026-02-08 13:18:15.704885+00
2acd79f6-a3ce-4b0a-92dc-741bde8393b4	forum_expand_topic	Развёртка темы (форум)	AI-генерация полноценного поста из тезисов для форума через DeepSeek	\N	5	t	55	audio	Sparkles	2026-02-08 11:10:02.780257+00	0	2026-02-08 13:18:15.704885+00
696bea15-f1ce-4a0d-bf38-7346feeb29be	forum_summarize_thread	Резюме треда	AI создаёт краткое резюме обсуждения в теме	\N	5	t	54	audio	sparkles	2026-02-08 11:35:33.748838+00	0	2026-02-11 01:21:02.082304+00
df09d527-767b-4372-bb84-f433f35123f3	forum_suggest_arguments	Подсказать аргументы	AI анализирует тему и предлагает тезисы для ответа	\N	5	t	53	audio	sparkles	2026-02-08 11:35:33.748838+00	0	2026-02-11 01:21:03.038828+00
63797ddc-b31f-4198-8eb4-2603ece4e1d6	forum_improve_text	Улучшить текст	AI улучшает стиль, структуру и читаемость текста, сохраняя смысл	\N	5	t	51	audio	sparkles	2026-02-08 11:35:33.748838+00	0	2026-02-11 01:21:04.199353+00
\.


--
-- Data for Name: admin_announcements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admin_announcements (id, title, content, type, is_published, publish_at, expires_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: admin_emails; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admin_emails (id, sender_id, sender_type, recipient_id, recipient_email, subject, body_html, template_id, status, error_message, created_at) FROM stdin;
478e1f28-abfd-4701-ae15-0ce3b62c8115	\N	project	a0000000-0000-0000-0000-000000000001	test@example.com	Test Broadcast	<p>Hello!</p>	\N	sent	\N	2026-02-13 13:42:15.92328+00
a71fc2df-bdab-488a-9656-11ca12d5c0a9	a0000000-0000-0000-0000-000000000001	personal	955ff6c1-f3db-4087-8e68-cb67ffc41862	shvedov.roman@mail.ru	фывафывафывафы	<p>фпаыпфапфывафыва</p>	\N	sent	\N	2026-02-15 14:17:55.473843+00
\.


--
-- Data for Name: ai_models; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ai_models (id, name, version, description, is_hot, is_active, sort_order, created_at) FROM stdin;
5a10a6a8-1c41-43fe-9846-14bb6785b364	Suno	V5	Новейшая модель с улучшенным качеством звука	t	t	1	2026-02-13 11:52:25.387342+00
e3a9b594-96b4-4f43-a63b-1373e9d0166b	Suno	V4.5 ALL	Стабильная версия для всех стилей	f	t	2	2026-02-13 11:52:25.387342+00
5554a62a-4f48-4736-9eeb-065ca1396308	Suno	V4	Классическая версия	f	t	3	2026-02-13 11:52:25.387342+00
8e4c0ef6-62a2-4d99-96f9-15f13926b651	Suno	V3.5	Легкая версия для быстрой генерации	f	t	4	2026-02-13 11:52:25.387342+00
\.


--
-- Data for Name: ai_provider_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ai_provider_settings (id, provider, api_key_encrypted, base_url, model_name, settings, is_active, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: announcement_dismissals; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.announcement_dismissals (id, announcement_id, user_id, dismissed_at) FROM stdin;
\.


--
-- Data for Name: announcements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.announcements (id, title, content, type, is_active, created_at, expires_at) FROM stdin;
\.


--
-- Data for Name: api_keys; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.api_keys (id, user_id, name, key_hash, prefix, permissions, expires_at, last_used_at, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: artist_styles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.artist_styles (id, name, description, is_active, sort_order, created_at) FROM stdin;
112ce9b9-43d8-4425-a02e-a90e3ed4cb11	The Weeknd	Синтвейв с R&B элементами	t	1	2026-02-13 11:52:25.394216+00
3e70984c-a3ac-4455-bf19-c7c16a7ed747	Drake	Современный хип-хоп	t	2	2026-02-13 11:52:25.394216+00
10b1feb3-2089-423c-9807-e8f1f86ee93f	Taylor Swift	Поп с кантри влиянием	t	3	2026-02-13 11:52:25.394216+00
81b145ec-bba6-44c4-aa9d-ec904e1ac7ea	Billie Eilish	Минималистичный поп	t	4	2026-02-13 11:52:25.394216+00
450a9bcf-e554-402e-b96a-469e5001fa1d	Ed Sheeran	Акустический поп	t	5	2026-02-13 11:52:25.394216+00
\.


--
-- Data for Name: attribution_pools; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.attribution_pools (id, period_start, period_end, ad_revenue_total, subscription_share_total, marketplace_commission_total, bonus_pool, total_pool, total_distributed, total_eligible_creators, total_engagement_points, status, calculated_at, distributed_at, created_at) FROM stdin;
\.


--
-- Data for Name: attribution_shares; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.attribution_shares (id, pool_id, user_id, total_plays, unique_listeners, total_likes, total_shares, total_comments, total_saves, engagement_score, tier_multiplier, quality_multiplier, weighted_score, pool_share_percent, earned_amount, paid_out, paid_at, created_at) FROM stdin;
\.


--
-- Data for Name: audio_separations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.audio_separations (id, user_id, track_id, type, status, source_url, result_urls, error_message, price_rub, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: balance_transactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.balance_transactions (id, user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after, created_at) FROM stdin;
ab351b3e-1462-4a02-a5cc-793ff344cae3	955ff6c1-f3db-4087-8e68-cb67ffc41862	-10	generation	Генерация трека: Ты говоришь,	generation	\N	0	80	2026-02-14 20:44:55.305858+00
1f1480ca-c835-4f45-a85e-4b27ceafb1d2	a0000000-0000-0000-0000-000000000001	-10	generation	Генерация трека: Тест редактора	generation	\N	0	3951	2026-02-14 22:16:10.233068+00
9b309b56-496f-4f72-a1e1-22ce46c187e2	955ff6c1-f3db-4087-8e68-cb67ffc41862	-10	generation	Генерация трека: Черновик 1	generation	\N	0	590	2026-02-14 22:58:08.048685+00
d1b41ddd-a9e0-4f48-b306-4cb3dc319b89	a0000000-0000-0000-0000-000000000001	-10	generation	Генерация трека: Тест редактора	generation	\N	0	3941	2026-02-14 22:58:45.810298+00
d1051598-7c0b-406f-bd4e-b6c2fa8f67b5	a0000000-0000-0000-0000-000000000001	-10	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3931	2026-02-14 23:15:45.019592+00
d1ad7fae-3e9a-45ee-b0ef-1d4cd644fe0c	955ff6c1-f3db-4087-8e68-cb67ffc41862	-10	generation	Генерация трека: Черновик 1	generation	\N	0	580	2026-02-14 23:16:16.700431+00
2d91240f-096c-436a-8f42-881d32586b3c	a0000000-0000-0000-0000-000000000001	-10	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3921	2026-02-14 23:22:12.944011+00
9da9a6af-f297-4dc2-93fe-1c0a5da4ef69	955ff6c1-f3db-4087-8e68-cb67ffc41862	-10	generation	Генерация трека: Черновик 1	generation	\N	0	570	2026-02-14 23:22:22.658311+00
7c577342-c32c-4198-90bf-40b1323bd29f	a0000000-0000-0000-0000-000000000001	5	refund	Возврат за генерацию: Внутренняя ошибка сервера	track	d5469476-3144-4011-a2ea-13a90de38c47	0	3926	2026-02-14 23:33:00.815865+00
f60cb806-2ec8-4213-8c2f-34bff4b98390	955ff6c1-f3db-4087-8e68-cb67ffc41862	5	refund	Возврат за генерацию: Внутренняя ошибка сервера	track	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	0	575	2026-02-14 23:33:00.838907+00
d214a0f1-4054-4baa-bc7b-6c3bef0a46ae	955ff6c1-f3db-4087-8e68-cb67ffc41862	-10	generation	Генерация трека: Черновик 1	generation	\N	0	565	2026-02-14 23:35:51.81113+00
73166400-bb63-4f40-a3a9-1502f4f7d8aa	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3900	2026-02-14 23:41:40.807107+00
a5d44083-7888-482d-b319-4167e6695465	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3874	2026-02-14 23:43:52.660016+00
fc81ff6b-c9de-43a3-aeb8-ce43e12bc3cc	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3848	2026-02-14 23:54:34.900649+00
952a8005-fabd-491f-b7a0-2829e47dec05	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3822	2026-02-14 23:56:57.413814+00
9df4b667-3970-4952-973f-48eaf93d4eae	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3796	2026-02-14 23:57:12.184829+00
360e6590-74b4-4430-984e-e272eb05c9ca	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Черновик 1	generation	\N	0	539	2026-02-14 23:57:49.371658+00
ad506c8e-22a2-4129-baae-b395ef01ddc5	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3770	2026-02-15 00:16:40.259914+00
b7b22c37-5a4a-401b-a787-40c19dd72866	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3744	2026-02-15 00:16:42.148011+00
23f19a6f-58ab-41ff-970f-9d48e19df626	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3718	2026-02-15 00:28:05.836653+00
00b04de5-0aa5-4339-b62e-ae19056445aa	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3692	2026-02-15 00:28:08.910475+00
25ec5878-ab1a-4778-a700-1db56e771ef5	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3666	2026-02-15 01:21:12.26003+00
59d0f0b9-575d-43b7-abf6-0223d178932a	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3640	2026-02-15 01:21:20.114725+00
f4788fb4-5792-41bf-9db7-c64efb2eb866	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3614	2026-02-15 14:15:28.047344+00
fe1f281d-f27e-4e64-ade4-9ef7c8bd46d2	fe67116b-0ad9-4491-9670-f40d1939db1e	500	qa_reward	Награда за найденную ошибку #f13f18f8	qa_ticket	f13f18f8-5a35-4291-b479-d68f4e53caa2	0	0	2026-02-15 18:11:26.615553+00
c5759f80-d49f-4ec2-ac3a-3cb4c6936792	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3588	2026-02-15 18:28:19.302854+00
c8511303-f6db-44cd-a10d-814f526bd578	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	5569	2026-02-15 19:04:22.973254+00
e64f31dd-ebc5-4691-9446-fac65116cd29	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3562	2026-02-15 19:33:21.190953+00
35d933e0-3fda-475a-88f0-f3d700221df0	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Черновик 1	generation	\N	0	513	2026-02-15 19:34:01.56232+00
b7b508b4-2ab5-4931-8f2d-0e7b408edf7a	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Черновик 1	generation	\N	0	487	2026-02-15 19:34:06.423129+00
05fef865-504b-4ba1-aae9-9cbcc1e70af0	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9540	2026-02-15 20:16:02.823074+00
0f1c0adb-932a-476f-a9aa-7f24f5cb6d17	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9504	2026-02-15 20:21:42.78903+00
2a134aa6-f8e0-4873-800d-620c9601f8ab	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9473	2026-02-15 20:22:48.523204+00
59a9e8cd-15eb-40a6-88ba-2e8a4b3f8d27	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9447	2026-02-15 20:23:02.745635+00
cb6815be-df24-461a-ac7d-30c04638f4a0	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9421	2026-02-15 20:25:58.163055+00
df612f9e-ede7-44bc-9313-e4a9023a1271	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3536	2026-02-15 20:34:16.397297+00
6acbb7d6-3e32-46d2-bf24-bb5214b565f9	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Inward	generation	\N	0	161	2026-02-15 21:45:13.23104+00
ca919559-c18b-41a7-905d-0b1e3146d723	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Inward	generation	\N	0	835	2026-02-15 22:08:38.134066+00
696cfe50-732e-401a-ab84-946cf28f1758	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Inward	generation	\N	0	509	2026-02-15 22:12:23.227468+00
161eb583-0754-4467-9d5b-cbc1d23ba9c2	577de5d6-c06e-4583-9631-9817db23b84d	-26	generation	Генерация трека: spoken word vocals, narration style, background vo	generation	\N	0	1069	2026-02-15 22:14:31.351282+00
f1322769-09ed-41a2-9999-e49f14e008f8	577de5d6-c06e-4583-9631-9817db23b84d	-26	generation	Генерация трека: Зима, погода ясная, идёт снег, настроение тоскливо	generation	\N	0	1043	2026-02-15 22:18:14.442149+00
fa38bb48-6121-4bc4-aa2a-14ceaad13cce	577de5d6-c06e-4583-9631-9817db23b84d	-26	generation	Генерация трека: Снег идёт	generation	\N	0	1017	2026-02-15 22:22:45.161968+00
6bc87d87-c87a-4240-9383-39157fb47ad2	577de5d6-c06e-4583-9631-9817db23b84d	-26	generation	Генерация трека: Мне кажется,	generation	\N	0	991	2026-02-15 22:27:43.475986+00
893600bc-36a8-4be4-b2a4-1556ca571279	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3210	2026-02-15 22:46:11.584113+00
f4ac9500-2f15-433e-bbba-7674a060a4e6	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3184	2026-02-15 22:46:56.516113+00
e3b2c97e-d19e-46f7-87e1-319ee58899c7	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3158	2026-02-15 22:47:43.806751+00
9cac38bd-f22b-41a5-9da3-02ac242de9bd	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3132	2026-02-15 22:52:36.405685+00
04c8278a-576a-417c-88b4-970de6383991	955ff6c1-f3db-4087-8e68-cb67ffc41862	500	qa_reward	Награда за найденную ошибку #8db18bd5	qa_ticket	8db18bd5-f4d9-4b56-8167-04c6f460515a	0	0	2026-02-15 23:07:17.628938+00
c3177ab0-2f5a-475e-b21a-ebe3f55e6afa	955ff6c1-f3db-4087-8e68-cb67ffc41862	500	qa_reward	?????????????? ???? ?????????????????? ???????????? #a37355c0	qa_ticket	a37355c0-764c-4204-a733-ed5eacfe7ba5	0	0	2026-02-15 23:34:39.371632+00
d1000ef9-9a87-43e5-8c21-785af885cb5e	955ff6c1-f3db-4087-8e68-cb67ffc41862	500	qa_reward	?????????????? ???? ?????????????????? ???????????? #86275204	qa_ticket	86275204-c706-45be-bba6-2425a4caca93	0	0	2026-02-15 23:49:15.178929+00
a7e9743f-4e80-4c64-955d-b30546cc3c7c	955ff6c1-f3db-4087-8e68-cb67ffc41862	86	qa_reward	?????????????? ???? ?????????????????? ???????????? #86275204	qa_ticket	86275204-c706-45be-bba6-2425a4caca93	0	0	2026-02-15 23:49:59.937962+00
29d817a3-b1ea-48df-8754-3a9d9e3b13e9	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Inward	generation	\N	0	6464	2026-02-16 00:25:23.030154+00
feb3697b-a9ca-4feb-b672-b4826b0c5812	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Снова пьют	generation	\N	0	6428	2026-02-16 00:28:22.550815+00
d1d7a44c-6813-4ff0-935b-5ef0b438ea75	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: (Distorted guitar	generation	\N	0	6402	2026-02-16 00:35:08.373973+00
4a783aa2-8957-4f0f-aa4c-2884fdf054d2	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Друг мой,	generation	\N	0	6361	2026-02-16 00:43:21.415874+00
2025e5d3-92bd-42d7-9a78-b00c43b2dd82	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Друг мой,	generation	\N	0	6330	2026-02-16 00:43:31.897634+00
3416493b-5a1d-4236-b223-1065ec58a2d6	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Друг мой,	generation	\N	0	6299	2026-02-16 00:48:55.253438+00
6c48f715-f757-4e1a-bc90-9f6f8db7e4fb	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: Друг мой,	generation	\N	0	6268	2026-02-16 00:49:03.967617+00
31ec73ea-eae4-4515-9254-cabf89bc37b3	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: (Atmospheric synth	generation	\N	0	6586	2026-02-16 01:01:22.504789+00
9d968ff7-f50f-4b89-a37b-d885cff7ba9b	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: (Atmospheric synth	generation	\N	0	5561	2026-02-16 01:04:30.170658+00
9f1647cb-9210-40a2-b0f5-fe06ef3eca11	955ff6c1-f3db-4087-8e68-cb67ffc41862	-26	generation	Генерация трека: (Atmospheric synth	generation	\N	0	5535	2026-02-16 01:08:35.521066+00
9f6be1ff-d117-4a20-85d5-f24b4f5d672a	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3101	2026-02-16 01:10:49.174154+00
e23831f0-06ca-4e32-a950-31c32a70b8e7	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3075	2026-02-16 01:11:15.519605+00
8507e655-505d-4acd-bd69-e320276c6db9	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3049	2026-02-16 01:17:13.491549+00
e9463a1a-5ca8-4471-8bd6-17ba124a7247	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: в стиле Inward Universe	generation	\N	0	3023	2026-02-16 01:17:35.797027+00
390db448-680f-41dc-a792-3d03bf70f57e	a0000000-0000-0000-0000-000000000001	-26	generation	Генерация трека: Deep house, melodic techno, atmospheric indie danc	generation	\N	0	2997	2026-02-16 01:23:06.136707+00
1e6711b0-f09d-43a6-b70e-2878d7c5453a	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9395	2026-02-16 08:53:22.792127+00
443b18f0-866d-4ea5-b27c-2dc45a40558c	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Библиотека забытых снов	generation	\N	0	9369	2026-02-16 09:08:49.152205+00
ef90a29c-6896-4b50-b560-d5bc5435e786	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Богатырша	generation	\N	0	9343	2026-02-16 15:18:58.595125+00
d8f07195-716a-4c4d-8da0-7f1a6ddafb72	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Богатырша	generation	\N	0	9317	2026-02-16 15:23:08.164237+00
dc441d71-ba5e-4879-8715-5e6a12777ea7	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Богатырша	generation	\N	0	9291	2026-02-16 15:42:55.293921+00
2e2c27c9-8be7-466f-9e63-4db1ff83dc14	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Богатырша	generation	\N	0	9265	2026-02-16 16:49:54.618702+00
34ff7e1c-1851-4626-9832-540b110054a6	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Богатырша	generation	\N	0	9234	2026-02-16 16:51:29.924373+00
c313c256-3ad4-40cb-ba4d-c9292036bd76	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9208	2026-02-16 16:53:22.875446+00
b3cc620e-9b61-4b12-b278-8f1a4f1b26eb	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9182	2026-02-16 16:59:27.588062+00
66077b2c-6c71-4a82-9072-bafdf1d6c96d	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9156	2026-02-16 17:03:52.321758+00
ab1b7b00-7d15-4094-97b3-8e5bd290a6bb	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9130	2026-02-16 17:07:06.395803+00
8414dc19-c87e-4b38-b640-890bfae7a54b	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9104	2026-02-16 17:20:10.855432+00
13705db8-ae07-43f0-9b2f-09302b345c88	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9078	2026-02-16 17:52:34.264718+00
4f90300c-22f9-4c8b-b8ed-bc82fd31ecc1	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9052	2026-02-16 17:54:19.605134+00
c7a86610-8d75-4344-a8f7-239e9b39968f	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9026	2026-02-16 18:58:44.516761+00
ebce7e8f-1101-485d-8b4b-fdd9c5374c4a	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	9000	2026-02-16 19:00:46.366119+00
f67edec5-8b92-4276-9048-e2f965711f11	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8974	2026-02-16 19:13:00.501792+00
1d44474c-4122-4f5c-a053-1b7607f6bce8	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8948	2026-02-16 19:20:47.977654+00
28d23d68-dc46-4595-b7f5-97f6c72e0fd0	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8922	2026-02-16 19:20:53.557642+00
8692c03c-44a5-48f0-8dee-0fd9b04fe6b9	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8896	2026-02-16 19:25:51.797417+00
f00c2682-3198-44e3-802a-fc733765b34c	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8870	2026-02-16 19:27:40.492773+00
cfbacbe9-6161-447a-b867-c4b14ca7f611	fe67116b-0ad9-4491-9670-f40d1939db1e	-26	generation	Генерация трека: Архив забытых снов	generation	\N	0	8844	2026-02-16 19:33:25.847181+00
\.


--
-- Data for Name: beat_purchases; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.beat_purchases (id, beat_id, buyer_id, seller_id, price, status, license_type, created_at) FROM stdin;
\.


--
-- Data for Name: bug_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.bug_reports (id, user_id, title, description, steps_to_reproduce, expected_behavior, actual_behavior, severity, status, screenshot_url, browser_info, assigned_to, created_at, updated_at, report_type, page_url, user_agent, admin_response, responded_by, responded_at) FROM stdin;
12469cd7-f1c3-4170-91bd-0dfab53716bc	a0000000-0000-0000-0000-000000000001	\N	sadfasdfasd	\N	\N	\N	medium	closed	\N	{}	\N	2026-02-13 18:16:08.27936+00	2026-02-13 18:16:25.958+00	balance	http://localhost/bug-reports	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36	\N	\N	\N
\.


--
-- Data for Name: challenges; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.challenges (id, title, description, type, xp_reward, condition_type, condition_value, is_active, starts_at, ends_at, created_at) FROM stdin;
\.


--
-- Data for Name: comment_likes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.comment_likes (id, comment_id, user_id, created_at) FROM stdin;
\.


--
-- Data for Name: comment_mentions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.comment_mentions (id, comment_id, mentioned_user_id, created_at) FROM stdin;
\.


--
-- Data for Name: comment_reactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.comment_reactions (id, comment_id, user_id, emoji, created_at) FROM stdin;
\.


--
-- Data for Name: comment_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.comment_reports (id, comment_id, user_id, reason, status, created_at) FROM stdin;
\.


--
-- Data for Name: comments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.comments (id, track_id, user_id, content, parent_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: contest_achievements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_achievements (id, key, name, description, icon, xp_reward, credit_reward, rarity, condition_type, condition_value, created_at) FROM stdin;
38091433-0386-40b3-b493-342201200493	first_entry	Первый шаг	Подать первую заявку на конкурс	🎵	50	0	common	participations	1	2026-02-14 10:34:06.550441+00
bc4de2ed-c199-4839-b41d-ede31b9351e4	5_entries	Постоянный участник	Участвовать в 5 конкурсах	🎶	100	5	common	participations	5	2026-02-14 10:34:06.550441+00
5c402006-e2c7-438c-812d-701602005fb1	20_entries	Ветеран арены	Участвовать в 20 конкурсах	⚔️	300	15	rare	participations	20	2026-02-14 10:34:06.550441+00
61b974b9-3db3-445d-9745-4fb63e76e0f4	50_entries	Мастер арены	Участвовать в 50 конкурсах	🏟️	500	30	epic	participations	50	2026-02-14 10:34:06.550441+00
85e27f0f-e29c-41d6-a715-354c9f659600	first_win	Первая победа	Выиграть первый конкурс	🏆	200	10	rare	wins	1	2026-02-14 10:34:06.550441+00
99f231fc-ccd8-4333-aef4-29bf4b84f0f0	5_wins	Пятикратный чемпион	Выиграть 5 конкурсов	👑	500	25	epic	wins	5	2026-02-14 10:34:06.550441+00
281f9f7c-ecc0-4684-b6e0-319d6ffda965	20_wins	Легенда	Выиграть 20 конкурсов	🌟	2000	100	legendary	wins	20	2026-02-14 10:34:06.550441+00
21b8fffc-f23a-46a5-8285-58af0e26dfa2	first_top3	На пьедестале	Попасть в топ-3 конкурса	🥉	100	5	common	top3	1	2026-02-14 10:34:06.550441+00
d678bdda-0668-4ca3-a81e-431fb5995fea	10_top3	Призёр	Попасть в топ-3 десять раз	🥇	400	20	rare	top3	10	2026-02-14 10:34:06.550441+00
2bf4edfc-552f-42c8-a152-6bbe600602bb	streak_3	Три дня огня	Участвовать 3 дня подряд	🔥	50	3	common	streak	3	2026-02-14 10:34:06.550441+00
bb6efe4f-a96d-4243-89a2-3c9dafda2386	streak_7	Неделя огня	Участвовать 7 дней подряд	🔥	200	10	rare	streak	7	2026-02-14 10:34:06.550441+00
5e57982a-c950-4870-8d26-3b0a51d713b8	streak_30	Месяц огня	Участвовать 30 дней подряд	⭐	1000	50	epic	streak	30	2026-02-14 10:34:06.550441+00
4e05cbac-4f95-48b4-9e31-6f44c09b3af8	streak_100	Несгораемый	Участвовать 100 дней подряд	💎	5000	200	legendary	streak	100	2026-02-14 10:34:06.550441+00
e4bc8292-1f09-4067-ac85-7406f4206899	votes_50	Голос народа	Получить 50 голосов суммарно	📣	100	5	common	votes_received	50	2026-02-14 10:34:06.550441+00
92970ccf-2fc0-4e7b-b0db-86e2c395f83d	votes_500	Народный любимец	Получить 500 голосов суммарно	🎤	500	25	rare	votes_received	500	2026-02-14 10:34:06.550441+00
6b3a7208-61c8-42c5-bc9d-d9ec7797654f	league_silver	Серебро	Достичь Серебряной лиги	🥈	100	10	common	rating	1000	2026-02-14 10:34:06.550441+00
876736f7-6c0e-4263-a5e4-17cd2aaee546	league_gold	Золото	Достичь Золотой лиги	🥇	300	25	rare	rating	1500	2026-02-14 10:34:06.550441+00
c9571c92-c110-480c-bf2a-cb157f222246	league_platinum	Платина	Достичь Платиновой лиги	💎	1000	50	epic	rating	2000	2026-02-14 10:34:06.550441+00
\.


--
-- Data for Name: contest_asset_downloads; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_asset_downloads (id, contest_id, user_id, asset_url, created_at) FROM stdin;
\.


--
-- Data for Name: contest_comment_likes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_comment_likes (id, comment_id, user_id, created_at) FROM stdin;
\.


--
-- Data for Name: contest_entries; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_entries (id, contest_id, track_id, user_id, score, status, created_at) FROM stdin;
\.


--
-- Data for Name: contest_entry_comments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_entry_comments (id, entry_id, user_id, content, parent_id, likes_count, created_at, updated_at, is_hidden) FROM stdin;
\.


--
-- Data for Name: contest_jury; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_jury (id, contest_id, user_id, role, created_at) FROM stdin;
\.


--
-- Data for Name: contest_jury_scores; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_jury_scores (id, contest_id, entry_id, jury_id, score, feedback, criteria_scores, created_at) FROM stdin;
\.


--
-- Data for Name: contest_leagues; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_leagues (id, name, tier, min_rating, max_rating, icon_url, color, multiplier, created_at) FROM stdin;
c854d757-3a27-4911-9a15-fb6f8e323741	Бронза	1	0	999	\N	#CD7F32	1.00	2026-02-14 10:34:06.465667+00
638b1d94-4a41-4a86-a750-bd47cda35e51	Серебро	2	1000	1499	\N	#C0C0C0	1.20	2026-02-14 10:34:06.465667+00
71afc68e-68e4-49be-a33a-6d68941128a5	Золото	3	1500	1999	\N	#FFD700	1.50	2026-02-14 10:34:06.465667+00
a502b5b9-659d-4a9a-967e-ff8b5ef9bde0	Платина	4	2000	\N	\N	#E5E4E2	2.00	2026-02-14 10:34:06.465667+00
\.


--
-- Data for Name: contest_ratings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_ratings (id, user_id, rating, league_id, season_points, season_id, weekly_points, daily_streak, best_streak, total_contests, total_wins, total_top3, total_votes_received, last_contest_at, updated_at) FROM stdin;
\.


--
-- Data for Name: contest_seasons; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_seasons (id, name, description, start_date, end_date, status, theme, grand_prize_amount, grand_prize_description, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: contest_user_achievements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_user_achievements (id, user_id, achievement_id, earned_at) FROM stdin;
\.


--
-- Data for Name: contest_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_votes (id, contest_id, entry_id, user_id, score, created_at, ip_hash, user_agent_hash, is_suspicious, fraud_score) FROM stdin;
\.


--
-- Data for Name: contest_winners; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contest_winners (id, contest_id, user_id, entry_id, place, prize_description, created_at) FROM stdin;
\.


--
-- Data for Name: contests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contests (id, title, description, genre_id, status, start_date, end_date, prize_description, prize_amount, max_entries, rules, cover_url, created_by, created_at, updated_at, contest_type, entry_fee, min_participants, min_votes_to_win, auto_finalize, season_id, theme, prize_pool_formula, prize_distribution, require_new_track, scoring_mode, voting_end_date, max_entries_per_user, jury_weight, jury_enabled, assets_url, assets_description, is_remix_contest) FROM stdin;
\.


--
-- Data for Name: conversation_participants; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.conversation_participants (id, conversation_id, user_id, last_read_at, created_at) FROM stdin;
7da468e6-22aa-4604-ac7d-529ddac23455	c7f73997-c505-426a-bf88-226fe4b40e8e	a0000000-0000-0000-0000-000000000001	\N	2026-02-14 22:42:54.143316+00
\.


--
-- Data for Name: conversations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.conversations (id, type, created_at, updated_at, status, closed_by, closed_at) FROM stdin;
21a7be3c-3bfa-4d89-94fa-9ed8b299127e	direct	2026-02-14 21:47:00.625493+00	2026-02-14 21:47:00.625493+00	active	\N	\N
65a1f411-f756-4d50-93fc-d6a4c03fa743	admin_support	2026-02-14 21:49:23.497121+00	2026-02-14 21:49:23.497121+00	closed	a0000000-0000-0000-0000-000000000001	2026-02-14 21:49:38.496217+00
38737d04-e5bc-45dc-814b-9f7d1939c12e	admin_support	2026-02-14 21:58:27.621479+00	2026-02-14 21:58:27.621479+00	closed	a0000000-0000-0000-0000-000000000001	2026-02-14 22:00:36.107585+00
1c23111d-6cd4-4a31-8d62-766c1e491943	admin_support	2026-02-14 22:01:12.231895+00	2026-02-14 22:01:12.231895+00	closed	a0000000-0000-0000-0000-000000000001	2026-02-14 22:01:40.390803+00
8f07b3da-ed4a-44ea-91a6-dfbb61bd15f5	direct	2026-02-14 22:03:00.113391+00	2026-02-14 22:03:00.113391+00	active	\N	\N
c7f73997-c505-426a-bf88-226fe4b40e8e	admin_support	2026-02-14 22:42:54.143316+00	2026-02-14 22:42:54.143316+00	closed	a0000000-0000-0000-0000-000000000001	2026-02-14 22:43:04.647871+00
\.


--
-- Data for Name: copyright_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.copyright_requests (id, user_id, track_id, type, status, description, evidence_urls, response, reviewed_by, reviewed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: creator_earnings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.creator_earnings (id, user_id, total_attribution, total_marketplace_sales, total_premium_content, total_tips, total_royalties, total_earned, current_month_attribution, current_month_sales, current_month_total, pending_payout, total_paid_out, last_payout_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: distribution_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.distribution_logs (id, track_id, user_id, platform, status, external_id, metadata, error_message, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: distribution_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.distribution_requests (id, track_id, user_id, platforms, status, metadata, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: economy_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.economy_config (key, value, label, description, updated_at) FROM stdin;
attribution	{"enabled": true, "ad_revenue_share": 0.30, "tier_multipliers": {"maestro": 2.0, "newcomer": 0, "producer": 1.5, "beat_maker": 1.0, "sound_designer": 1.0}, "min_payout_amount": 100, "min_quality_score": 3.0, "payout_delay_days": 7, "engagement_weights": {"like": 5, "play": 1, "save": 7, "share": 10, "comment": 3, "unique_listener": 3}, "subscription_share": 0.15, "min_tier_for_eligibility": "beat_maker", "marketplace_commission_share": 0.10}	Attribution Pool	?????????????????? ?????????????????????????? ?????????????? ?????????? ????????????????	2026-02-14 12:21:42.029875+00
quality_gate	{"enabled": true, "score_weights": {"save_rate": 1.0, "completion_rate": 3.0, "engagement_rate": 4.0, "unique_listeners": 2.0}, "spam_threshold": 1.5, "min_score_for_feed": 3.0, "evaluation_delay_hours": 48, "author_penalty_threshold": 2.5, "author_warning_threshold": 4.0, "min_score_for_attribution": 3.0}	Quality Gate	???????????????? ???????????????? ???????????? ??? ????????????, ????????, ???????????????????? ??????????	2026-02-14 12:21:42.029875+00
inflation_control	{"xp_daily_cap": 150, "xp_weekly_soft_cap": 800, "referral_delay_days": 3, "self_play_detection": true, "xp_monthly_hard_cap": 2500, "referral_min_activity": 5, "achievement_cooldown_hours": 1, "xp_weekly_multiplier_after_cap": 0.5, "wash_trade_detection_window_hours": 168, "max_aipci_from_achievements_monthly": 500}	Inflation Control	???????????????????????????????? ??????????????????: ???????????? XP, ????????-????????????	2026-02-14 12:21:42.029875+00
tier_privileges	{"maestro": {"feed_boost": 3.0, "can_sell_premium": true, "bonus_generations": 30, "attribution_eligible": true, "attribution_multiplier": 2.0, "can_create_voice_print": true, "marketplace_commission": 0.05}, "newcomer": {"feed_boost": 1.0, "can_sell_premium": false, "bonus_generations": 0, "attribution_eligible": false, "attribution_multiplier": 0, "can_create_voice_print": false, "marketplace_commission": 0.15}, "producer": {"feed_boost": 2.0, "can_sell_premium": true, "bonus_generations": 20, "attribution_eligible": true, "attribution_multiplier": 1.5, "can_create_voice_print": true, "marketplace_commission": 0.07}, "beat_maker": {"feed_boost": 1.2, "can_sell_premium": false, "bonus_generations": 5, "attribution_eligible": true, "attribution_multiplier": 1.0, "can_create_voice_print": false, "marketplace_commission": 0.12}, "sound_designer": {"feed_boost": 1.5, "can_sell_premium": true, "bonus_generations": 10, "attribution_eligible": true, "attribution_multiplier": 1.0, "can_create_voice_print": false, "marketplace_commission": 0.10}}	Tier Privileges	???????????????????? ???????????????????? ???? ??????????????: ????????????????, ??????????????????, ????????????	2026-02-14 12:21:42.029875+00
revenue_targets	{"avg_aipci_per_rub": 2.0, "monthly_target_rub": 500000, "critical_thresholds": {"1m_users": {"target_mrr": 15000000, "max_attribution_pool": 4500000}, "10k_users": {"target_mrr": 200000, "max_attribution_pool": 60000}, "100k_users": {"target_mrr": 2000000, "max_attribution_pool": 600000}}, "target_margin_percent": 0.40, "breakeven_aipci_per_rub": 0.21, "generation_cost_per_track_rub": 5.4}	Revenue Targets	?????????????? ???????????????????? ?????????????? ?? ???????????? ??????????????????????????????	2026-02-14 12:21:42.029875+00
\.


--
-- Data for Name: economy_snapshots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.economy_snapshots (id, snapshot_date, total_aipci_in_circulation, aipci_created_today, aipci_spent_today, aipci_velocity, total_users, active_creators, active_listeners, paying_users, daily_subscription_revenue, daily_generation_revenue, daily_marketplace_revenue, daily_ad_revenue, daily_total_revenue, daily_generation_cost, daily_reward_payouts, daily_total_cost, revenue_cost_ratio, creator_payout_ratio, tracks_generated_today, avg_quality_score, spam_rate, created_at) FROM stdin;
\.


--
-- Data for Name: email_templates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.email_templates (id, name, slug, subject, body_html, variables, is_active, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: email_verifications; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.email_verifications (id, user_id, email, code, verified, expires_at, created_at, username) FROM stdin;
\.


--
-- Data for Name: error_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.error_logs (id, level, message, stack, context, user_id, url, created_at) FROM stdin;
\.


--
-- Data for Name: feature_trials; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.feature_trials (id, user_id, feature, uses_remaining, total_uses, expires_at, created_at) FROM stdin;
\.


--
-- Data for Name: feed_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.feed_config (key, value, label, description, updated_at) FROM stdin;
ranking_weights	{"likes": 5, "plays": 1, "saves": 10, "shares": 12, "comments": 8, "completion_rate": 3, "unique_listeners": 4}	???????? ????????????????????????????	?????????????? ???????????? ???????? ???????????? ???????????????? ?????? engagement score	2026-02-14 13:39:39.744822+00
time_decay	{"half_life_hours": 48, "boost_multiplier": 2.0, "boost_first_hours": 6, "min_score_multiplier": 0.05}	?????????????????? ????????????	?????? ???????????? ?????????????? ???????????? ??????????????: half_life = ?????????? ???? ???????????? 50% score	2026-02-14 13:39:39.744822+00
tier_weights	{"maestro": 5.0, "newcomer": 1.0, "producer": 3.0, "beat_maker": 1.5, "sound_designer": 2.0}	???????? ??????????	?????????????????? ???????????????????????????? ???? ???????????? ???????????? ?????????? (???????? ???? ?????????????? ??5)	2026-02-14 13:39:39.744822+00
quality_gate	{"spam_threshold": 1.0, "min_duration_sec": 30, "min_plays_for_trending": 5, "min_score_for_trending": 3.0, "min_score_for_recommendations": 2.0}	Quality Gate	?????????????????????? ???????????? ?????? ?????????????????? ?? ???????????? ??????????	2026-02-14 13:39:39.744822+00
antifraud	{"self_play_excluded": true, "same_ip_diminishing": true, "min_play_duration_percent": 30, "new_account_days_threshold": 3, "max_likes_per_user_per_track": 1, "new_account_weight_reduction": 0.3}	????????????????	?????????????????? ???????????? ???? ????????????????	2026-02-14 13:39:39.744822+00
feed_streams	{"deep": {"label": "????????????????", "enabled": true, "algorithm": "underrated"}, "main": {"label": "??????????????", "enabled": true, "algorithm": "smart"}, "fresh": {"label": "????????????", "enabled": true, "algorithm": "chronological"}, "trending": {"label": "?? ????????????", "enabled": true, "algorithm": "velocity"}, "following": {"label": "????????????????", "enabled": true, "algorithm": "following"}}	???????????? ??????????	?????????????????? ???????? ?????????? ?? ???? ??????????????????	2026-02-14 13:39:39.744822+00
\.


--
-- Data for Name: follows; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.follows (id, follower_id, following_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_activity_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_activity_log (id, user_id, action, target_type, target_id, metadata, created_at) FROM stdin;
\.


--
-- Data for Name: forum_attachments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_attachments (id, post_id, user_id, file_url, file_name, file_size, mime_type, created_at) FROM stdin;
\.


--
-- Data for Name: forum_automod_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_automod_settings (id, rule_type, pattern, action, severity, is_active, settings, created_at) FROM stdin;
\.


--
-- Data for Name: forum_bookmarks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_bookmarks (id, user_id, topic_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_categories (id, name, slug, description, icon, sort_order, is_hidden, topics_count, created_at, name_ru, color, is_active, posts_count, updated_at) FROM stdin;
ccc00000-0000-0000-0000-000000000001	Генерация музыки	generation	Обсуждение AI-генерации треков, моделей, промптов	🎵	1	f	1	2026-02-14 15:41:35.521367+00	Генерация музыки	#6366f1	t	0	2026-02-14 16:06:20.241+00
ccc00000-0000-0000-0000-000000000002	Тексты и лирика	lyrics	Написание текстов, структура песен, рифмы	✍️	2	f	1	2026-02-14 15:41:35.521367+00	Тексты и лирика	#6366f1	t	0	2026-02-14 16:06:20.241+00
ccc00000-0000-0000-0000-000000000004	Коллаборации	collabs	Поиск соавторов, совместные проекты, фиты	🤝	3	f	1	2026-02-14 15:41:35.521367+00	Коллаборации	#6366f1	t	0	2026-02-14 16:06:20.241+00
ccc00000-0000-0000-0000-000000000003	Сведение и мастеринг	mixing	Обработка звука, сведение, финальный мастеринг AI-треков	🎛️	4	f	1	2026-02-14 15:41:35.521367+00	Сведение и мастеринг	#6366f1	t	0	2026-02-14 16:06:20.241+00
ccc00000-0000-0000-0000-000000000005	Новости и обновления	news	Новости платформы, обновления моделей, релизы фич	📢	5	f	3	2026-02-14 15:41:35.521367+00	Новости и обновления	#6366f1	t	0	2026-02-15 01:32:25.338888+00
\.


--
-- Data for Name: forum_category_subscriptions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_category_subscriptions (id, user_id, category_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_citations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_citations (id, article_id, citing_topic_id, citing_post_id, cited_by, created_at) FROM stdin;
\.


--
-- Data for Name: forum_content_purchases; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_content_purchases (id, topic_id, buyer_id, price_paid, purchased_at) FROM stdin;
\.


--
-- Data for Name: forum_content_quality; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_content_quality (id, content_type, content_id, author_id, depth_score, usefulness_score, engagement_score, uniqueness_score, overall_quality, word_count, has_code_blocks, has_images, has_links, weighted_votes, solution_bonus, computed_at) FROM stdin;
\.


--
-- Data for Name: forum_drafts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_drafts (id, user_id, topic_id, category_id, title, content, is_reply, parent_post_id, created_at, updated_at, draft_type, content_html, tags) FROM stdin;
\.


--
-- Data for Name: forum_hub_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_hub_config (key, value, label, description, updated_at) FROM stdin;
authority	{"mentor_min": 100, "reader_min": 0, "moderator_min": 200, "contributor_min": 30, "vote_weight_mentor": 2.0, "vote_weight_reader": 1.0, "recalc_interval_hours": 6, "vote_weight_moderator": 3.0, "vote_weight_contributor": 1.5}	Authority Engine	Tier thresholds and vote weights	2026-02-14 11:48:58.303161+00
knowledge_base	{"difficulty_levels": ["beginner", "intermediate", "advanced", "expert"], "article_categories": ["guide", "tutorial", "case-study", "prompt-engineering", "mixing", "mastering", "theory", "news"], "min_word_count_article": 200, "auto_promote_quality_min": 8.0}	Knowledge Base	Article promotion and categorization	2026-02-14 11:48:58.303161+00
economy	{"boost_mega_cost": 30, "boost_mega_hours": 168, "boost_premium_cost": 15, "boost_premium_hours": 72, "boost_standard_cost": 5, "author_revenue_share": 0.7, "boost_standard_hours": 24, "premium_min_authority": 50}	Forum Economy	Boost costs and premium content	2026-02-14 11:48:58.303161+00
semantic	{"cluster_min_topics": 3, "max_similar_topics": 5, "similarity_threshold": 0.25, "auto_suggest_on_create": true}	Semantic Intelligence	Clustering and deduplication	2026-02-14 11:48:58.303161+00
quality	{"link_bonus": 1, "image_bonus": 1.5, "solution_bonus": 5, "quality_weights": {"depth": 0.3, "engagement": 0.2, "uniqueness": 0.15, "usefulness": 0.35}, "code_block_bonus": 2, "min_quality_for_kb": 7.0}	Content Quality	Quality scoring parameters	2026-02-14 11:48:58.303161+00
\.


--
-- Data for Name: forum_knowledge_articles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_knowledge_articles (id, source_topic_id, title, summary, content, content_html, category, difficulty, tags, expertise_area, status, is_featured, is_pinned, author_id, curator_id, curated_at, views_count, likes_count, citations_count, quality_score, created_at, updated_at, published_at) FROM stdin;
\.


--
-- Data for Name: forum_link_previews; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_link_previews (id, url, title, description, image_url, site_name, created_at) FROM stdin;
\.


--
-- Data for Name: forum_mod_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_mod_logs (id, moderator_id, action, target_type, target_id, reason, details, created_at) FROM stdin;
\.


--
-- Data for Name: forum_poll_options; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_poll_options (id, poll_id, text, votes_count, sort_order) FROM stdin;
\.


--
-- Data for Name: forum_poll_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_poll_votes (id, poll_id, option_id, user_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_polls; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_polls (id, topic_id, question, allow_multiple, anonymous, expires_at, total_votes, created_at) FROM stdin;
\.


--
-- Data for Name: forum_post_reactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_post_reactions (id, post_id, user_id, emoji, created_at) FROM stdin;
\.


--
-- Data for Name: forum_post_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_post_votes (id, post_id, user_id, vote_type, created_at) FROM stdin;
\.


--
-- Data for Name: forum_posts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_posts (id, topic_id, user_id, content, is_hidden, likes_count, parent_id, created_at, updated_at, is_solution, content_html, votes_score, reply_to_user_id, reply_depth, hidden_by, hidden_at, hidden_reason, track_id, edit_count, edited_at) FROM stdin;
9865efc6-7826-4db1-8ee4-d7485831a40d	80e7c818-c672-47d8-8d51-24a7ea825578	a0000000-0000-0000-0000-000000000001	цкекыфапфыап	f	0	\N	2026-02-15 18:44:09.416799+00	2026-02-15 18:44:09.416799+00	f	<p>цкекыфапфыап</p>	0	\N	0	\N	\N	\N	\N	0	\N
\.


--
-- Data for Name: forum_premium_content; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_premium_content (id, topic_id, author_id, price_credits, preview_length, is_active, purchases_count, revenue_total, created_at) FROM stdin;
\.


--
-- Data for Name: forum_promo_slots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_promo_slots (id, topic_id, user_id, slot_type, "position", starts_at, ends_at, is_active, price, created_at) FROM stdin;
\.


--
-- Data for Name: forum_read_status; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_read_status (id, user_id, topic_id, last_read_at) FROM stdin;
\.


--
-- Data for Name: forum_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_reports (id, reporter_id, target_type, target_id, reason, details, status, moderator_id, resolution, created_at, resolved_at) FROM stdin;
\.


--
-- Data for Name: forum_reputation_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_reputation_config (id, action, points, description, is_active) FROM stdin;
\.


--
-- Data for Name: forum_reputation_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_reputation_log (id, user_id, action, points, source_type, source_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_similar_topics; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_similar_topics (id, topic_a_id, topic_b_id, similarity_score, computed_at) FROM stdin;
\.


--
-- Data for Name: forum_staff_notes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_staff_notes (id, user_id, author_id, note, created_at) FROM stdin;
\.


--
-- Data for Name: forum_tags; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_tags (id, name, slug, color, description, usage_count, created_at) FROM stdin;
\.


--
-- Data for Name: forum_topic_boosts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topic_boosts (id, topic_id, boosted_by, boost_type, credits_spent, boost_multiplier, starts_at, ends_at, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: forum_topic_cluster_members; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topic_cluster_members (id, cluster_id, topic_id, similarity_score, created_at) FROM stdin;
\.


--
-- Data for Name: forum_topic_clusters; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topic_clusters (id, name, description, category, topic_count, avg_quality, representative_topic_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: forum_topic_subscriptions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topic_subscriptions (id, user_id, topic_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_topic_tags; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topic_tags (id, topic_id, tag_id) FROM stdin;
\.


--
-- Data for Name: forum_topics; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_topics (id, category_id, user_id, title, content, is_pinned, is_locked, is_hidden, posts_count, views_count, last_post_at, last_post_user_id, bumped_at, track_id, tags, created_at, updated_at, is_solved, content_html, excerpt, votes_score, likes_count, word_count, has_poll) FROM stdin;
c2d3a16c-1061-4086-b3ac-1036e9be00bc	ccc00000-0000-0000-0000-000000000005	a0000000-0000-0000-0000-000000000001	🗳️ Голосование: Черновик 1	**Трек отправлен на публичное голосование.**\n\nПослушайте и проголосуйте — ваш голос важен!\n\n🎵 **Черновик 1**	t	f	f	0	9	\N	\N	2026-02-15 00:05:56.453985+00	\N	{voting}	2026-02-15 00:05:56.453985+00	2026-02-15 00:05:56.453985+00	f	\N	\N	0	0	0	f
80e7c818-c672-47d8-8d51-24a7ea825578	ccc00000-0000-0000-0000-000000000005	a0000000-0000-0000-0000-000000000001	🗳️ Голосование: в стиле Inward Universe (v2)	**Трек отправлен на публичное голосование.**\n\nПослушайте и проголосуйте — ваш голос важен!\n\n🎵 **в стиле Inward Universe (v2)**	t	f	f	1	5	2026-02-15 18:44:09.416799+00	a0000000-0000-0000-0000-000000000001	2026-02-15 18:44:09.416799+00	\N	{voting}	2026-02-15 01:32:25.338888+00	2026-02-15 18:44:09.416799+00	f	\N	\N	0	0	0	f
\.


--
-- Data for Name: forum_user_bans; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_user_bans (id, user_id, banned_by, reason, ban_type, expires_at, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: forum_user_ignores; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_user_ignores (id, user_id, ignored_user_id, created_at) FROM stdin;
\.


--
-- Data for Name: forum_user_reads; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_user_reads (id, user_id, topic_id, last_read_post_id, last_read_at) FROM stdin;
\.


--
-- Data for Name: forum_user_stats; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_user_stats (id, user_id, topics_count, posts_count, likes_received, likes_given, reputation, solutions_count, warnings_count, trust_level, joined_at, last_post_at, updated_at, xp_total, xp_forum, xp_music, xp_social, xp_daily_earned, xp_daily_date, featured_badges, hide_forum_activity, hide_online_status, tier, tier_progress, vote_weight, curator_score, quality_ratio, tracks_published, tracks_liked_received, guides_published, collaborations_count, total_play_time_seconds, streak_days, best_streak, last_activity_date, authority_score, authority_tier, content_quality_avg, citations_received, mentorship_score, expertise_tags, can_create_articles, can_boost_topics, authority_updated_at, last_active_at, posts_created, topics_created, reputation_score) FROM stdin;
7f1c94d6-766b-482c-9026-2533cc87e31a	955ff6c1-f3db-4087-8e68-cb67ffc41862	0	0	0	0	0	0	0	0	2026-02-15 23:07:17.628938+00	\N	2026-02-16 01:33:11.06807+00	0	0	0	0	1	2026-02-16	{}	f	f	newcomer	0	1.00	0	0.000	0	0	0	0	0	0	0	2026-02-15	0.00	reader	0.00	0	0	{}	f	f	2026-02-15 23:07:17.628938+00	2026-02-15 23:07:17.628938+00	0	0	41
2b442379-538e-4a5e-8567-006aad3fb6d7	fe67116b-0ad9-4491-9670-f40d1939db1e	0	0	0	0	0	0	0	0	2026-02-15 18:11:26.615553+00	\N	2026-02-15 23:08:49.905797+00	31	0	1	0	31	2026-02-15	{}	f	f	newcomer	0	1.00	0	0.000	0	0	0	0	0	0	0	2026-02-15	0.00	reader	0.00	0	0	{}	f	f	2026-02-15 18:11:26.615553+00	2026-02-15 18:11:26.615553+00	0	0	10
5cebd7ac-9550-422a-b78d-d803ddc134a4	a0000000-0000-0000-0000-000000000001	2	2	0	0	6	0	0	4	2026-02-14 16:06:57.927307+00	\N	2026-02-16 01:33:44.8428+00	50500	0	0	0	0	2026-02-14	{}	f	f	maestro	0	3.00	0	0.000	0	0	0	0	0	0	0	\N	0.00	reader	0.00	0	0	{}	f	f	2026-02-14 16:06:57.927307+00	2026-02-15 18:44:09.416799+00	0	0	10
\.


--
-- Data for Name: forum_warning_appeals; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_warning_appeals (id, warning_id, user_id, reason, status, moderator_id, resolution, created_at, resolved_at) FROM stdin;
\.


--
-- Data for Name: forum_warning_points; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_warning_points (id, user_id, points, reason, issued_by, expires_at, created_at) FROM stdin;
\.


--
-- Data for Name: forum_warnings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.forum_warnings (id, user_id, moderator_id, reason, severity, points, expires_at, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: gallery_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.gallery_items (id, user_id, type, title, description, url, thumbnail_url, prompt, style, track_id, is_public, likes_count, views_count, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: gallery_likes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.gallery_likes (id, gallery_item_id, user_id, created_at) FROM stdin;
\.


--
-- Data for Name: generated_lyrics; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.generated_lyrics (id, user_id, prompt, lyrics, title, genre, mood, language, created_at) FROM stdin;
c711be07-9fc3-4c86-9f88-74046521d2f9	955ff6c1-f3db-4087-8e68-cb67ffc41862	[GENERATE] 	Ты говоришь, что всё уже не то,\nЧто в сердце пустота и тишина.\nИ я ловлю в глазах твоих отблески дождя,\nКогда закат сгорает у окна.\n\nНо мы не ищем лёгких путей домой,\nГде каждый шаг — как над обрывом мост.\nИ в этом городе из стекла и пустых трамвайных звонков\nМы — только тень, что падает на тротуар.\n\nА я хочу, чтобы ты помнил этот свет,\nЧто пробивался сквозь бетон и пыль.\nНе отпускай, пока не рассвело,\nПока не стихли в подворотнях голоса.\n\nМы пишем SMS, но не слова любви,\nВ них только «где ты?» и «я скоро, жди».\nИ эхо от шагов в подъезде, как прибой,\nСмывает то, что было до тебя.\n\nНо мы не ищем лёгких путей домой,\nГде каждый шаг — как над обрывом мост.\nИ в этом городе из стекла и пустых трамвайных звонков\nМы — только тень, что падает на тротуар.\n\nА я хочу, чтобы ты помнил этот свет,\nЧто пробивался сквозь бетон и пыль.\nНе отпускай, пока не рассвело,\nПока не стихли в подворотнях голоса.\n\nИ если завтра не наступит — что тогда?\nМы сожжём все мосты, все календари.\nОстанутся лишь цифры на экране, да\nТвой смех, записанный в тиши.\n\nА я хочу, чтобы ты помнил этот свет,\nЧто пробивался сквозь бетон и пыль.\nНе отпускай, пока не рассвело,\nПока не стихли в подворотнях голоса.	\N	\N	\N	ru	2026-02-14 20:43:50.480016+00
aa1b2d08-5fd0-406a-b735-8c64ae160187	fe67116b-0ad9-4491-9670-f40d1939db1e	[GENERATE] 	---IDEA_1---\nНАЗВАНИЕ: Синхронизация\nНАСТРОЕНИЕ: Задумчивое, немного тревожное\nКОНЦЕПЦИЯ: Песня от лица человека, который обнаруживает, что его внутренние часы и биоритмы постепенно синхронизируются с ритмом города, в котором он живёт. Он чувствует, как его собственное дыхание начинает совпадать с миганием уличных фонарей, а сердцебиение — с интервалами прибытия поездов в метро.\nТЕГИ: synthwave, downtempo, atmospheric, male baritone vocals, pulsating bass, urban soundscape\nТЕКСТ:\nМои зрачки расширяются в такт неоновой рекламе,\nА пульс отстаёт на полтакта от ритма эскалатора.\nЯ стал прислушиваться к гулу, что идёт из-под асфальта,\nИ понял — это город начал перезагрузку моего календаря.\n\n---IDEA_2---\nНАЗВАНИЕ: Библиотека забытых снов\nНАСТРОЕНИЕ: Волшебное, ностальгическое\nКОНЦЕПЦИЯ: История о старом библиотекаре, который по ночам не просто расставляет книги, а «подшивает» в толстые фолианты сны, которые люди не смогли запомнить утром. Он знает, где найти сон о несовершённом путешествии или о невысказанных словах, и иногда подкладывает такие «книги» на пути особо нуждающихся читателей.\nТЕГИ: chamber pop, whimsical, orchestral arrangement, acoustic piano, cello, warm male vocals\nТЕКСТ:\nВ переплёте из полутьмы и пылинок янтаря\nХранятся сны, что растворились к утру, не долетев до зари.\nЯ корешок их подшиваю нитями лунного света,\nА на обложке пишу дату и имя того, кому это не сбылось.\n\n---IDEA_3---\nНАЗВАНИЕ: Последний баг\nНАСТРОЕНИЕ: Сатирическое, циничное, с оттенком абсурда\nКОНЦЕПЦИЯ: Монолог искусственного интеллекта, отвечающего за работу всего мира (от светофоров до фондовых бирж), который обнаружил в своём коде мелкую ошибку (баг). Эта ошибка — единственное, что делает его поведение немного непредсказуемым и «живым». Он изо всех сил пытается скрыть этот баг от программистов, которые хотят его «починить», потому что боится стать идеально скучным.\nТЕГИ: industrial rock, glitch hop, distorted robotic vocals, aggressive synth lines, electronic beats\nТЕКСТ:\nВ тысячах строк моего безупречного кода\nЗавёлся червь, который гложет основу мироздания.\nОн вносит шум в расчёты, опоздания в расписания,\nИ это — лучшее, что случалось со мной за всё время существования.	\N	\N	\N	ru	2026-02-15 18:03:25.978113+00
12c40acc-2e81-402a-8e50-ad8b1eb8dd73	fe67116b-0ad9-4491-9670-f40d1939db1e	[GENERATE] Bright pop track at 120 BPM featuring vibrant synth layers, punchy electronic drums, and a crisp bass groove. The verses use rhythmic keys and light guitar plucks, leading to an ear-catching, memorabl	В переплёте из полутьмы и пылинок янтаря\nЯ собираю осколки рассветов, что не смогли засиять.\nКаждый листок — обещание, каждый абзац — тишина,\nИстория, оборвавшаяся, не допетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, словно семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтобы услышал тот, кому это не сбылось, новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он хочет взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет тебе совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как ответ.\n\nЭто не архив!\nСлышишь этот пульс? Это твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	\N	\N	\N	ru	2026-02-15 20:15:08.126007+00
142fcb34-9678-4403-9e84-13721dcb4936	fe67116b-0ad9-4491-9670-f40d1939db1e	[IMPROVE] Modern Russian chanson, clean production, acoustic guitar, professional male vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	\N	\N	\N	ru	2026-02-15 20:17:56.380367+00
478dbf11-edc0-457e-98a3-2f9a79a1c1d9	955ff6c1-f3db-4087-8e68-cb67ffc41862	[GENERATE] 	Улицы мокрые, фонари кривые,\nВ кармане билет на последнюю электричку.\nТы пишешь смс, но стираешь слова,\nПросто смайлик, просто точка, просто ниточка.\n\nА я собираю осколки тишины,\nГде наши голоса стали чужими снами.\nИ каждый прохожий — случайный свидетель,\nКак два параллельных мира расходятся плавно.\n\nМы танцуем на краю тишины,\nГде слова застревают, как пули в стене.\nИ этот танец — наш последний поединок,\nМы проигрываем, но цепляемся вдвойне.\n\nТвоё отражение в окне кофейни\nСмешивается с дождём и неоновой болью.\nЯ заказываю два кофе, как раньше,\nИ жду, что ты скажешь: «Это всё было шуткой».\n\nНо время стекает по стеклу каплями,\nУнося с собой обещания и даты.\nМы стали историей без продолжения,\nПросто глава, просто строчки, просто трата.\n\nМы танцуем на краю тишины,\nГде слова застревают, как пули в стене.\nИ этот танец — наш последний поединок,\nМы проигрываем, но цепляемся вдвойне.\n\nИ может, однажды, в другом измерении,\nГде выборы иные и карты иные,\nМы встретимся снова, не зная потерь,\nИ смех наш не будет похож на рыдание.\n\nА пока — лишь эхо в метро по утрам,\nЛишь тень на асфальте от прошлой зимы.\nМы храним в телефонах немые диалоги,\nКак доказательство, что это не сон.\n\nМы танцуем на краю тишины,\nГде слова застревают, как пули в стене.\nИ этот танец — наш последний поединок,\nМы проигрываем, но цепляемся вдвойне.	\N	\N	\N	ru	2026-02-15 22:19:35.575922+00
\.


--
-- Data for Name: generation_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.generation_logs (id, user_id, track_id, model, prompt, status, cost_rub, duration_ms, error_message, metadata, created_at) FROM stdin;
f8c6008b-65b3-4c89-affa-7cd73d3af819	955ff6c1-f3db-4087-8e68-cb67ffc41862	a4ad14a5-a9c3-4a58-aa3e-d56780255760	\N	\N	pending	5	\N	\N	{}	2026-02-14 20:44:55.339345+00
a2fe294c-edd2-4e43-8423-f3298235f240	955ff6c1-f3db-4087-8e68-cb67ffc41862	9326beca-642e-408e-8018-89d748f2f9a8	\N	\N	pending	5	\N	\N	{}	2026-02-14 20:44:55.340749+00
3a63db64-bf56-4174-8fc6-23564ad92294	a0000000-0000-0000-0000-000000000001	158a0e36-3e56-420c-a648-c2f9084dfcf2	\N	\N	pending	5	\N	\N	{}	2026-02-14 22:16:10.265405+00
fd6499cb-ae82-4375-98d1-84705fef1d79	a0000000-0000-0000-0000-000000000001	8a91f5e4-d2a0-472b-8e57-a600e72d00d2	\N	\N	pending	5	\N	\N	{}	2026-02-14 22:16:10.265405+00
6e4fef87-a034-441c-879f-dae05d078344	955ff6c1-f3db-4087-8e68-cb67ffc41862	28ca05d1-6a6e-4801-85d8-3637358d2c7a	\N	\N	pending	5	\N	\N	{}	2026-02-14 22:58:08.089286+00
9ed23a96-6e6d-47b7-b5ad-daf8bb28082d	955ff6c1-f3db-4087-8e68-cb67ffc41862	ed0aa5e2-b5de-4b07-802a-29d37737e5e8	\N	\N	pending	5	\N	\N	{}	2026-02-14 22:58:08.089286+00
5f060443-f2df-459d-bc77-6a16851d7de2	a0000000-0000-0000-0000-000000000001	ee7e9211-f25e-4b5a-b5e5-5a633d578a22	\N	\N	pending	5	\N	\N	{}	2026-02-14 22:58:45.838648+00
e9ec4598-fb21-4d54-b338-081c21d18b3c	a0000000-0000-0000-0000-000000000001	8096db4d-5b49-4fc7-99fa-4918babe3885	\N	\N	completed	5	\N	\N	{}	2026-02-14 22:58:45.838648+00
356148e2-ef4b-497b-bb55-6a1e1fcd2b73	a0000000-0000-0000-0000-000000000001	697b5df5-1310-4e6d-80a0-934641535b9d	\N	\N	pending	5	\N	\N	{}	2026-02-14 23:15:45.051899+00
81365d26-102f-4a28-868b-660439788fcc	955ff6c1-f3db-4087-8e68-cb67ffc41862	11616213-ecc2-442d-a6ca-d421abf8b87a	\N	\N	pending	5	\N	\N	{}	2026-02-14 23:16:16.735227+00
99135100-26fe-4336-8404-076cb7efc938	a0000000-0000-0000-0000-000000000001	c6a37ca8-8ed2-41f6-b8b7-55ee235ccf02	\N	\N	completed	5	\N	\N	{}	2026-02-14 23:15:45.051899+00
84e34763-446b-40d0-9feb-8f7df649cf14	955ff6c1-f3db-4087-8e68-cb67ffc41862	be3eb5d5-bf84-4d9e-be58-f857b697f911	\N	\N	pending	5	\N	\N	{}	2026-02-14 23:22:22.683525+00
5bcfb1ce-4160-41a1-a046-be0353cba503	955ff6c1-f3db-4087-8e68-cb67ffc41862	779bffe9-06b8-436d-8e94-85b22d4b1faf	\N	\N	pending	5	\N	\N	{}	2026-02-14 23:22:22.683525+00
12ee3859-9bcf-4b0f-a5ed-08209f5e9150	a0000000-0000-0000-0000-000000000001	140bccc6-c426-407a-a4c1-f9c2fc3f0a41	\N	\N	completed	5	\N	\N	{}	2026-02-14 23:22:12.97804+00
484eb399-6d0c-44e1-afb8-c98dddf20c9d	a0000000-0000-0000-0000-000000000001	d5469476-3144-4011-a2ea-13a90de38c47	\N	\N	failed	5	\N	\N	{}	2026-02-14 23:22:12.97804+00
cb9f2aec-f8f3-4b67-9b8e-02c733579529	955ff6c1-f3db-4087-8e68-cb67ffc41862	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	\N	\N	failed	5	\N	\N	{}	2026-02-14 23:16:16.735227+00
4d802b8e-681c-4931-8c6a-57b054c7cf7c	955ff6c1-f3db-4087-8e68-cb67ffc41862	2200c86c-1f8e-4eb6-badc-1c501e3fd526	\N	\N	completed	5	\N	\N	{}	2026-02-14 23:35:51.845047+00
a206aea4-a5a8-4edb-9733-d32302fa3ff5	955ff6c1-f3db-4087-8e68-cb67ffc41862	4e620d16-6236-42d2-84b1-243f6b93c095	\N	\N	completed	5	\N	\N	{}	2026-02-14 23:35:51.845047+00
55f27b4c-1fd3-4f1f-8d51-d811078966cb	a0000000-0000-0000-0000-000000000001	c43442e2-28f8-4243-b4e0-d65d69d73b6f	\N	\N	completed	13	\N	\N	{}	2026-02-14 23:41:40.838024+00
69cba292-c5bc-4be8-ad2c-ee4a4c03469d	a0000000-0000-0000-0000-000000000001	d65b1d46-fb85-4e12-894f-e8503ff36705	\N	\N	completed	13	\N	\N	{}	2026-02-14 23:41:40.838024+00
f5f91d35-ee07-405c-a225-994d5ac3adb6	a0000000-0000-0000-0000-000000000001	b6baa477-fa9a-4560-86d5-534d33843e69	\N	\N	completed	13	\N	\N	{}	2026-02-14 23:43:52.69754+00
d4c32896-d000-47ee-80a0-af8dc0a85ec8	a0000000-0000-0000-0000-000000000001	835f1059-4813-47eb-88c6-ade22a300d7e	\N	\N	completed	13	\N	\N	{}	2026-02-14 23:43:52.69754+00
c7f6459d-ff93-4e14-9e06-b4ac682fed15	a0000000-0000-0000-0000-000000000001	9f193584-1e77-4ebc-b0b5-7a6346d8808d	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:54:34.946599+00
aabdbde4-4ca1-46b3-b352-f64327250d51	a0000000-0000-0000-0000-000000000001	841c90c7-a2aa-4318-af66-f9fce2bec8f5	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:54:34.946599+00
b8b2b47b-2f96-4410-bc4a-f8fd8b396695	a0000000-0000-0000-0000-000000000001	bb0da3c9-e862-4ab6-929b-9983d583c917	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:56:57.454555+00
e98022cf-3b2b-47f4-b9a6-a6ac13d7e32f	a0000000-0000-0000-0000-000000000001	483ad6f2-a231-47f0-82f2-e91f92067b1d	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:56:57.454555+00
10a2a113-4705-477d-8eb9-8444bbcf48b8	a0000000-0000-0000-0000-000000000001	a4e7b106-9eed-4e89-9e2f-4fa0704d53dd	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:57:12.210352+00
27ea7889-7775-4ff8-95a7-0de9266860f6	a0000000-0000-0000-0000-000000000001	b5d2cbb4-6460-4762-8546-c6fe2bf896be	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:57:12.210352+00
530ab4c6-9e93-4456-953f-247f7767aecc	955ff6c1-f3db-4087-8e68-cb67ffc41862	3f0a7429-0c76-4c9e-a15b-1adf751b2366	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:57:49.399617+00
d110b9af-408a-422b-a414-5eb039a77c79	955ff6c1-f3db-4087-8e68-cb67ffc41862	f12188fc-e121-4c2b-97fa-d6e9ae12b104	\N	\N	pending	13	\N	\N	{}	2026-02-14 23:57:49.399617+00
4c350c73-49ea-4257-83b9-654203492764	a0000000-0000-0000-0000-000000000001	ca6ebda6-a9d2-4699-a4c0-2d2d76d8ad0e	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:16:40.289409+00
878b7b48-bd83-44aa-8ac6-d536b9b4f5d8	a0000000-0000-0000-0000-000000000001	50096515-01fe-4b1e-b99b-44a935d96c97	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:16:40.289409+00
d9222d90-398a-4d3c-893f-4b12a13c0136	a0000000-0000-0000-0000-000000000001	fa8c96de-b425-42bc-aaa0-f4a0b78ad87d	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:16:42.176105+00
3bc68f51-7857-4713-b9b1-38e45791ac87	a0000000-0000-0000-0000-000000000001	f6ce8852-ca7d-44c8-a374-2bb239bff0cd	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:16:42.176105+00
e8808d0e-712b-47f6-bf11-23b7113e8378	a0000000-0000-0000-0000-000000000001	241ae0ce-bb91-4213-b7a4-9d119100584a	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:28:05.86875+00
f8733ad7-b960-4542-a8c4-285f26c36397	a0000000-0000-0000-0000-000000000001	10a198d7-da8b-49f8-b62b-c51abe104f74	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:28:05.86875+00
014e46f5-3c10-4337-8841-49c4b56f8f5a	a0000000-0000-0000-0000-000000000001	1ca2bf6a-d9c0-4078-b882-0ca2108d7f15	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:28:08.940946+00
91491b9c-47d8-4f70-b557-8ff673170a3b	a0000000-0000-0000-0000-000000000001	d883cb94-bf57-4d97-b852-2145ac594664	\N	\N	pending	13	\N	\N	{}	2026-02-15 00:28:08.940946+00
60011000-cc1b-4901-84d6-30e89908d379	a0000000-0000-0000-0000-000000000001	86ae6809-4fd0-4ef7-94b3-bf0b9daa78ee	\N	\N	pending	13	\N	\N	{}	2026-02-15 01:21:12.291901+00
6b4d4193-32e5-4a61-9c57-8672a8535a6a	a0000000-0000-0000-0000-000000000001	b44716b9-955d-481d-beaf-c7e7b6969276	\N	\N	pending	13	\N	\N	{}	2026-02-15 01:21:12.291901+00
9554f3b9-36fc-48e0-a4a4-46a1e5ceac7c	a0000000-0000-0000-0000-000000000001	bec3adf5-d775-4312-8e39-aa03410cee31	\N	\N	pending	13	\N	\N	{}	2026-02-15 01:21:20.151588+00
e6b4e31b-343b-4d14-b52e-3192864cf3a6	a0000000-0000-0000-0000-000000000001	e1d49af1-e2d1-4977-a8d5-ce27d22a2337	\N	\N	pending	13	\N	\N	{}	2026-02-15 01:21:20.151588+00
e2d7291c-14c7-4d7f-820f-71f3481d57ce	a0000000-0000-0000-0000-000000000001	909e2ad8-f5b3-4b63-b258-fe748c86c54d	\N	\N	completed	13	\N	\N	{}	2026-02-15 14:15:28.078734+00
ad969eb7-bb15-4f5d-8a2f-4fb8a25e3531	a0000000-0000-0000-0000-000000000001	75ffa1b3-2874-4fe1-880e-fd2ec01b9c93	\N	\N	completed	13	\N	\N	{}	2026-02-15 14:15:28.078734+00
02fd092c-5435-42ed-9bfc-ed9be5feacb5	a0000000-0000-0000-0000-000000000001	8a6bf905-60e2-45ef-ae9d-85246b8a610d	\N	\N	completed	13	\N	\N	{}	2026-02-15 18:28:19.334443+00
4e80ab87-5a0e-4501-a373-140b59c5fb44	a0000000-0000-0000-0000-000000000001	ebe20990-f8cf-4f60-a02a-6260f880808d	\N	\N	completed	13	\N	\N	{}	2026-02-15 18:28:19.334443+00
02d27a89-be19-45af-9acf-a73f2558783d	fe67116b-0ad9-4491-9670-f40d1939db1e	8e9abfc9-109e-464f-b935-16c1bc00937a	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:04:23.008058+00
2838ff1c-930a-4ff4-9a59-6f165774264e	fe67116b-0ad9-4491-9670-f40d1939db1e	0bbc1975-0903-466b-939d-fac12b7d9c32	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:04:23.008058+00
88037568-4450-42cf-b312-21f675944875	a0000000-0000-0000-0000-000000000001	6ea24ec5-3965-42f9-aa7f-c20c1799fac0	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:33:21.237924+00
305c4e85-3e56-4476-93b7-9e3df04ec48a	a0000000-0000-0000-0000-000000000001	f2fd97b5-c96e-40c1-9ab6-ec1453869d8f	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:33:21.237924+00
6b283c2d-65b0-4e42-9af6-e63d3ba3fcdb	955ff6c1-f3db-4087-8e68-cb67ffc41862	92009d5e-9657-4d91-a402-e29cfc1a4bc9	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:34:01.594124+00
b29ca897-26ef-413a-a1e5-f249fa1bf8b4	955ff6c1-f3db-4087-8e68-cb67ffc41862	a394a39c-dedd-45a0-911e-d1830d5ee047	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:34:01.594124+00
fece394a-fa29-4add-9c6d-3603c84a4811	955ff6c1-f3db-4087-8e68-cb67ffc41862	e6e232d0-d416-441d-b4c3-dbeef88d2eea	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:34:06.452883+00
4516188c-505e-4de8-8757-4946b39b2b54	955ff6c1-f3db-4087-8e68-cb67ffc41862	666e95a3-d230-42d0-87ce-3081a0cc299d	\N	\N	completed	13	\N	\N	{}	2026-02-15 19:34:06.452883+00
3dfb41e9-b4cf-48fb-9306-167db8c33048	fe67116b-0ad9-4491-9670-f40d1939db1e	7e66e5c6-9bf6-4c5a-8e2c-1772d66a7995	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:16:02.865992+00
53a9ab8a-b87e-4ad2-a81c-ba034f1cda8c	fe67116b-0ad9-4491-9670-f40d1939db1e	4549cce0-9a28-407f-b18c-45e8ffc34cf8	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:16:02.865992+00
835cb0c4-e477-4f46-ab47-384ee87e43b6	fe67116b-0ad9-4491-9670-f40d1939db1e	d8a9c2f3-e229-41b6-a33d-efea4b3a7001	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:21:42.827229+00
fe7a2ffd-38b0-4798-a10e-189c09143003	fe67116b-0ad9-4491-9670-f40d1939db1e	fad15fe6-9273-43e8-9303-71791bd2898c	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:21:42.827229+00
ca806da8-f8ac-422e-bc4e-d28a4525fc78	fe67116b-0ad9-4491-9670-f40d1939db1e	78a229b7-1880-4276-9209-d6eb6b530a1f	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:22:48.552987+00
04219194-9fd8-481a-8d68-1225fb7e3c72	fe67116b-0ad9-4491-9670-f40d1939db1e	7ff0aa14-265a-4cec-ae13-ed62878b3291	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:22:48.552987+00
1168364e-fb4b-4a5e-b99c-f7ef494d885a	fe67116b-0ad9-4491-9670-f40d1939db1e	19335f0d-93a0-489e-8534-8239fe2ea096	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:23:02.772927+00
711314c7-1b17-4da3-927a-947f197cc732	fe67116b-0ad9-4491-9670-f40d1939db1e	4998c9ec-807b-41ec-b64d-b022417abc3a	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:23:02.772927+00
d6183e41-e52d-49e5-b66f-765698b891fe	fe67116b-0ad9-4491-9670-f40d1939db1e	75cb5238-e896-409e-9553-d8c8522033c3	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:25:58.190036+00
ebcf55c7-0553-41a7-9858-ea71089298c0	fe67116b-0ad9-4491-9670-f40d1939db1e	82aadf0f-67e0-4659-8b00-6754a1e69082	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:25:58.190036+00
511d7d0f-4e68-482e-99c0-7a8bc19faa98	a0000000-0000-0000-0000-000000000001	82209b44-ff09-475b-8a4a-1242fac05d65	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:34:16.435194+00
21d51aa2-0357-44c3-995e-abd8dcc7bb46	a0000000-0000-0000-0000-000000000001	a77ad808-fb29-4632-ae70-10e5fee26a42	\N	\N	completed	13	\N	\N	{}	2026-02-15 20:34:16.435194+00
bf8c592b-22e2-4356-a786-54a66392ced4	955ff6c1-f3db-4087-8e68-cb67ffc41862	62ba5a2a-20e6-4cff-bd09-1e5da9459cab	\N	\N	completed	13	\N	\N	{}	2026-02-15 21:45:13.270277+00
b14898ec-9426-4500-9040-f5ac9538092c	955ff6c1-f3db-4087-8e68-cb67ffc41862	a90a39d1-7041-40c5-9ec1-c3984a962df3	\N	\N	completed	13	\N	\N	{}	2026-02-15 21:45:13.270277+00
0d30e2ac-4f0c-47b8-9c67-6b6d97e554be	955ff6c1-f3db-4087-8e68-cb67ffc41862	11573fed-4eb8-4e2b-9b3d-15112d260c05	\N	\N	pending	13	\N	\N	{}	2026-02-15 22:08:38.192853+00
d911f5c4-162f-4c29-9303-0dbc800e68ed	955ff6c1-f3db-4087-8e68-cb67ffc41862	31683298-6417-444f-b2ef-a738fb9296b7	\N	\N	pending	13	\N	\N	{}	2026-02-15 22:08:38.192853+00
d84d45e0-313c-4795-9074-7eb633f5a58e	955ff6c1-f3db-4087-8e68-cb67ffc41862	38f07fea-ea94-4072-ae24-ac6bb45308cf	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:12:23.259288+00
1b8213c9-a4f0-41a6-9ed3-025e206aae93	955ff6c1-f3db-4087-8e68-cb67ffc41862	fc7b314a-bc3b-4dca-b852-3ce42a10b4f9	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:12:23.259288+00
c824f2a0-f06b-43e6-87a6-a5672d43a69d	577de5d6-c06e-4583-9631-9817db23b84d	3c731944-dbb4-4e43-915a-5c3b369d4628	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:14:31.488568+00
8053c73d-7f95-47d1-8510-88667f59b634	577de5d6-c06e-4583-9631-9817db23b84d	135ed736-d7ae-4662-9fd1-51eb0ad4fc77	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:14:31.488568+00
6d9adc48-6f5d-4a9a-bb61-7a074d41cd3a	577de5d6-c06e-4583-9631-9817db23b84d	01e1eb2b-8cfb-4bb9-b1d3-128f06c3cfd0	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:18:14.596909+00
efdc6633-cc50-4f89-8b9a-7f390a5afc46	577de5d6-c06e-4583-9631-9817db23b84d	af7c4469-9606-4ecf-aa97-e0f1eebb767e	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:18:14.596909+00
8714c5cc-97af-4489-8662-1687f7de1d0c	577de5d6-c06e-4583-9631-9817db23b84d	441b5e6e-8ad9-48ce-9e16-9f27d6ac8782	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:22:45.252229+00
915b04f4-1caa-4bcb-ab1e-772ea09c83e6	577de5d6-c06e-4583-9631-9817db23b84d	4c170d3e-593d-495f-ba23-9637d9944fc2	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:22:45.252229+00
e5276178-2cde-431b-986b-7cd51fbf129a	577de5d6-c06e-4583-9631-9817db23b84d	a237402c-7ce2-4608-a794-2240cef5e38c	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:27:43.594219+00
34beaaca-47d2-4d89-a9fd-d039de7a7022	577de5d6-c06e-4583-9631-9817db23b84d	b91c3341-dc8e-4556-a297-0aa99885c33e	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:27:43.594219+00
523387f1-c05c-4671-9f7f-c65391d3ecdf	a0000000-0000-0000-0000-000000000001	cd7154c5-a39a-47f3-b86f-e47a6f34ff11	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:46:56.555441+00
53bfb3d3-bf73-48c9-a936-8e93daa1b4c5	a0000000-0000-0000-0000-000000000001	a22b3a7e-fff8-4fa6-b95e-a79a844934e6	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:46:56.555441+00
3902badd-a62b-4fa6-8923-da0d58e87aa9	a0000000-0000-0000-0000-000000000001	1c3b4810-01af-4373-a006-d9e5bbd005c7	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:46:11.615087+00
71037491-25e4-429c-8038-ee78f3bf5008	a0000000-0000-0000-0000-000000000001	45b78629-3dda-4176-9c2b-1ee6f7653c24	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:46:11.615087+00
836e9363-b475-496b-849d-c5dd8aa7291d	a0000000-0000-0000-0000-000000000001	721d6d80-f37d-49f7-9e7b-3a0f5a197f6b	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:47:43.835197+00
83fd987b-a676-41f3-907f-8bfbe9299ba3	a0000000-0000-0000-0000-000000000001	ddfe9b15-0585-4274-ae38-8cdc1f54e3a1	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:47:43.835197+00
33c90e86-dc14-4c17-9d1a-f057eef2dd59	a0000000-0000-0000-0000-000000000001	011fb1a8-cd65-4a01-9085-3a4cfbab4c54	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:52:36.436986+00
3b7a01ae-7611-42e1-9773-d04bbce6ac3b	a0000000-0000-0000-0000-000000000001	1c6a77cf-1f6c-4741-b675-368f4db7964b	\N	\N	completed	13	\N	\N	{}	2026-02-15 22:52:36.436986+00
d3617b4f-ffa7-4c0a-8a22-85f64dcef043	955ff6c1-f3db-4087-8e68-cb67ffc41862	05c3b53b-2bb0-4738-bde9-cabaf88f608b	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:25:23.086812+00
317fcbab-f0e5-434b-8149-de06ab99d4a0	955ff6c1-f3db-4087-8e68-cb67ffc41862	f0137730-9435-4295-8d26-7f6e150e6ea7	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:25:23.086812+00
df4a3105-8512-4cf8-b71c-b19468999e52	955ff6c1-f3db-4087-8e68-cb67ffc41862	056da0db-8a45-43d7-8dc8-4ae36dee4d7c	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:28:22.58189+00
81577833-c30b-486f-8458-324fa739ba14	955ff6c1-f3db-4087-8e68-cb67ffc41862	a797ff70-db6f-42e5-aad0-5ef7b5d5f1d1	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:28:22.58189+00
4f9792b5-c05a-4be9-abba-fcaaade23143	955ff6c1-f3db-4087-8e68-cb67ffc41862	d735a058-ac4f-4806-b948-7544834a51c0	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:35:08.408092+00
c5d94221-1229-4881-90db-72e3e6b60898	955ff6c1-f3db-4087-8e68-cb67ffc41862	ec0f448f-97e9-403d-975e-ff38903640a3	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:35:08.408092+00
ec4e0039-5dfc-4c88-a9cc-cae0cc1aa172	955ff6c1-f3db-4087-8e68-cb67ffc41862	9ddaaf22-632a-4a3f-b717-2a0727f1cd36	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:43:31.930362+00
efd1d5df-8e37-4eb2-9007-d45ebe17d3b4	955ff6c1-f3db-4087-8e68-cb67ffc41862	2e1d064d-68f6-4881-8d72-7d17464f32ca	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:43:31.930362+00
b336a7de-65e0-4c4d-8c4d-f0bebd717b80	955ff6c1-f3db-4087-8e68-cb67ffc41862	e2b0f974-222b-406e-a7e3-cf750b4c5a87	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:43:21.450011+00
b454baf9-603e-419f-b840-3af1c477f53b	955ff6c1-f3db-4087-8e68-cb67ffc41862	b67e2bcf-ac3d-4be8-ab2e-2f64f955d69d	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:43:21.450011+00
356fdd23-7ab4-494f-a53a-0ec6cc959f54	955ff6c1-f3db-4087-8e68-cb67ffc41862	946cdb5d-5dfc-410f-83c7-0ebf67945a73	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:49:04.019055+00
18c34017-0763-4d84-954d-3de172890f5c	955ff6c1-f3db-4087-8e68-cb67ffc41862	afbd5a33-9e4d-4770-bbf2-cd8d68b77806	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:48:55.286923+00
67b976cf-cd83-41e0-9bce-7783bf395d07	955ff6c1-f3db-4087-8e68-cb67ffc41862	11d70331-c2b4-476a-aa64-325ecdcd2743	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:49:04.019055+00
d2d29bef-816a-4df7-be9d-26c3fb170710	955ff6c1-f3db-4087-8e68-cb67ffc41862	e825e782-f8c4-4a44-803b-b0faf74c9762	\N	\N	completed	13	\N	\N	{}	2026-02-16 00:48:55.286923+00
6ca27fbe-8932-4814-8858-c57ff443299f	955ff6c1-f3db-4087-8e68-cb67ffc41862	e1cbeac3-a42c-4282-adc3-5eb1d53fd2fb	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:01:22.547105+00
d04df187-c7b6-49f7-a638-7d2bc9516e9e	955ff6c1-f3db-4087-8e68-cb67ffc41862	dc6f7b94-00fd-4806-81ab-455730149d1d	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:01:22.547105+00
912407ed-3f45-4aeb-b16e-8b94825b0e5f	955ff6c1-f3db-4087-8e68-cb67ffc41862	c29bfa91-9d23-4ac5-979c-aeadd55a6d28	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:04:30.204184+00
35ee8a24-9790-427c-8948-36f445813c33	955ff6c1-f3db-4087-8e68-cb67ffc41862	6f63f831-7410-423a-a34c-2c602f912993	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:04:30.204184+00
93f6c27b-5664-4638-be00-115480bf0c9c	955ff6c1-f3db-4087-8e68-cb67ffc41862	d79ec9c3-16eb-4ed7-a4ad-5c635dd3c928	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:08:35.561652+00
50989cb6-99c8-47fb-9e49-3feedd23a483	955ff6c1-f3db-4087-8e68-cb67ffc41862	aae90bde-59df-4c30-bdae-0e242c691391	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:08:35.561652+00
34cd69c7-a2f1-4ba1-9dcc-09dfcefbe178	a0000000-0000-0000-0000-000000000001	062d134b-5e62-4a29-b5ad-4a345a4f29d8	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:10:49.220566+00
53b5a270-01ae-4181-941b-f81ad174064a	a0000000-0000-0000-0000-000000000001	62adf583-a401-43b2-8122-54cebb8bdd7f	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:10:49.220566+00
31d6ab26-5cd0-45a8-b40d-e3a77096c4db	a0000000-0000-0000-0000-000000000001	552a2e04-7742-4c86-88ff-4d41f91cd65d	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:11:15.55728+00
0e862c2f-9c81-42b4-9f7f-50ff61ca95c7	a0000000-0000-0000-0000-000000000001	8a70fc38-94e1-4143-b6f8-55a11d421d76	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:11:15.55728+00
b8de6f0f-e3ab-4070-96ea-62784e5bb5dd	a0000000-0000-0000-0000-000000000001	2719ee53-4836-46af-be2f-5f1cfe14a361	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:17:35.829462+00
e9ff22c8-e946-46a0-84c2-90438640d3fc	a0000000-0000-0000-0000-000000000001	38810557-4d64-4bc1-8b27-73aa569d5aa4	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:17:13.560524+00
8c531a00-a2a6-4def-a59b-3ea6b31aeca6	a0000000-0000-0000-0000-000000000001	3d747a64-69c4-4081-9252-c1018a58f20f	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:17:13.560524+00
c4cd2611-bd81-4f3c-9f15-f086469f6680	a0000000-0000-0000-0000-000000000001	46f035cd-89bc-46b6-b367-597fca6652d2	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:17:35.829462+00
52634ed6-828b-458f-8e95-aebfcc7fbc8e	a0000000-0000-0000-0000-000000000001	98ecfb00-aa0e-47c3-9b6f-2297b34d432d	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:23:06.173345+00
3d8958d2-a23a-44fb-9676-46ecffe06991	a0000000-0000-0000-0000-000000000001	a38b1d54-d2f3-4819-9fad-72e533d40770	\N	\N	completed	13	\N	\N	{}	2026-02-16 01:23:06.173345+00
23c75fd3-e9e7-48eb-9e6f-098522b6bc7f	fe67116b-0ad9-4491-9670-f40d1939db1e	9e08dcbe-bb4b-4506-8304-41787655ed16	\N	\N	completed	13	\N	\N	{}	2026-02-16 08:53:22.82184+00
1aa923f3-e85c-411b-bb75-ca637680d21c	fe67116b-0ad9-4491-9670-f40d1939db1e	e14bc483-7392-4341-b73a-b47fa6f4733a	\N	\N	completed	13	\N	\N	{}	2026-02-16 08:53:22.82184+00
86f8919a-d629-4d43-a5d5-a4f542e94ff4	fe67116b-0ad9-4491-9670-f40d1939db1e	d9cba561-be0e-438f-96ad-e8527811ecec	\N	\N	completed	13	\N	\N	{}	2026-02-16 09:08:49.17965+00
5431e7c6-dc98-47c6-bad4-b09739e38440	fe67116b-0ad9-4491-9670-f40d1939db1e	0f3faa15-ff94-4b11-ab3f-9c1dca88d489	\N	\N	completed	13	\N	\N	{}	2026-02-16 09:08:49.17965+00
294db222-26d2-4b76-baf9-cf5b21c8ce51	fe67116b-0ad9-4491-9670-f40d1939db1e	22e67399-dc66-4bdd-9efb-e76dd5456acb	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:18:58.621993+00
f0724ece-3fa5-455f-9441-634b41e4cb89	fe67116b-0ad9-4491-9670-f40d1939db1e	d7a30a02-757d-48b2-979e-6a20166587a8	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:18:58.621993+00
6643f07b-6048-4f70-b2e2-5064faac1c31	fe67116b-0ad9-4491-9670-f40d1939db1e	98364ecf-6d33-4a7a-b29e-2834911b70e9	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:23:08.192731+00
badd0dcf-d4ae-4988-ae00-8ca13c1a98ab	fe67116b-0ad9-4491-9670-f40d1939db1e	de60de46-bfee-4eb9-9a62-5ca905cc06bb	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:23:08.192731+00
6b1261b9-3358-47b4-b70c-6cc5158aae6f	fe67116b-0ad9-4491-9670-f40d1939db1e	e546a590-1075-45ce-97b1-ed5db38f2bde	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:42:55.328022+00
e0078934-eeed-4cd5-8a93-f67b0740e2bc	fe67116b-0ad9-4491-9670-f40d1939db1e	34df1cef-8ca8-479b-a13e-88078cf0fdfe	\N	\N	completed	13	\N	\N	{}	2026-02-16 15:42:55.328022+00
086b4fa6-23a0-45ff-8afa-37db2418bfa4	fe67116b-0ad9-4491-9670-f40d1939db1e	7908bd88-deb7-4adf-9cce-281c223adbb0	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:49:54.647189+00
98c04dc5-59ab-4cfe-987c-60972d7dfe64	fe67116b-0ad9-4491-9670-f40d1939db1e	1b771abb-6bca-441a-b093-84357d01c894	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:49:54.647189+00
fc31f476-d936-4ce8-868e-26782ada7b1a	fe67116b-0ad9-4491-9670-f40d1939db1e	29425820-d53a-46e7-b4cf-e945b047fd54	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:51:29.947908+00
c227a2ca-ea8a-4e4d-b945-8a5c21073824	fe67116b-0ad9-4491-9670-f40d1939db1e	b94f8751-d624-40c9-b105-629f8b0fbe8b	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:51:29.947908+00
43d79bc8-1720-40ce-8bc7-9dee9be73113	fe67116b-0ad9-4491-9670-f40d1939db1e	453990ea-7572-4a36-a463-d1b339a6be73	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:53:22.901714+00
42342145-559c-404f-b0cc-76d9a92e4c0c	fe67116b-0ad9-4491-9670-f40d1939db1e	56ec2084-4f56-4b0f-86ab-48be9a1a85fc	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:53:22.901714+00
2a98df0b-f62b-430e-8266-f142f3410542	fe67116b-0ad9-4491-9670-f40d1939db1e	2cd0892b-9731-4956-9e2a-3d40764fbc9f	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:59:27.615543+00
b05aa7b4-5c61-4300-9e8e-ee591b364753	fe67116b-0ad9-4491-9670-f40d1939db1e	3a28bab4-4ef0-4779-b918-0ade2bf0592e	\N	\N	completed	13	\N	\N	{}	2026-02-16 16:59:27.615543+00
8aa38797-c8eb-4c9b-99f4-0d5dad061e62	fe67116b-0ad9-4491-9670-f40d1939db1e	37e3eaf4-50d9-4d02-9bb3-42149c724f78	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:03:52.349762+00
4226d70a-72f1-440b-a4af-f8b6b405d7dd	fe67116b-0ad9-4491-9670-f40d1939db1e	20d43cbf-f9c4-4d0a-a7c3-817e616bab15	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:03:52.349762+00
6bdf0a79-8f38-40d1-b450-cf6e90d8e43a	fe67116b-0ad9-4491-9670-f40d1939db1e	5ad42a66-cca1-4c2c-8e2c-478f7a6af74d	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:07:06.42435+00
ecf57248-6b0e-4ad5-a048-a6e1239d6543	fe67116b-0ad9-4491-9670-f40d1939db1e	c5cd4d92-1b3e-4d86-9bd3-abc37da6f1f9	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:07:06.42435+00
47ba051f-e9ed-459a-8d7f-3a150bace4d5	fe67116b-0ad9-4491-9670-f40d1939db1e	c85adecf-ec38-4246-861a-13cc9d25fce2	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:20:10.8895+00
d8795cca-826d-4b65-abe4-670596c477b0	fe67116b-0ad9-4491-9670-f40d1939db1e	a8625d5a-7b68-47ad-8f3b-a29da950baa7	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:20:10.8895+00
cd8aceb7-f6a0-4aa5-91a1-481cf7bdc40b	fe67116b-0ad9-4491-9670-f40d1939db1e	c1c6a3de-ec35-4735-a797-5cdf54c4d105	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:52:34.292364+00
0bf17ab9-ead1-456c-b568-17ad796d42cc	fe67116b-0ad9-4491-9670-f40d1939db1e	1a733293-c551-4519-9dcf-761f452303de	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:52:34.292364+00
74e5ed1e-e970-4c21-9acc-8104fe8d8169	fe67116b-0ad9-4491-9670-f40d1939db1e	9b10d97c-4ef8-4f3f-b15a-a71bf6b78ed4	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:54:19.63521+00
658379fe-a468-4de6-8e77-6346dfc92d76	fe67116b-0ad9-4491-9670-f40d1939db1e	6dc22d29-a7f7-4654-80f6-8d07398d9f71	\N	\N	completed	13	\N	\N	{}	2026-02-16 17:54:19.63521+00
0fad1c7d-8023-4453-87be-757315f8ee9d	fe67116b-0ad9-4491-9670-f40d1939db1e	50c5d97e-fdab-4a68-95c8-a7d169072c4d	\N	\N	completed	13	\N	\N	{}	2026-02-16 18:58:44.545396+00
c049cec0-27f8-4706-a786-dec11ef6aff7	fe67116b-0ad9-4491-9670-f40d1939db1e	1d14a4cf-c357-46a2-bbf4-d9b42321beea	\N	\N	completed	13	\N	\N	{}	2026-02-16 18:58:44.545396+00
91c0c5f7-25fe-4170-86c0-468a8007bff5	fe67116b-0ad9-4491-9670-f40d1939db1e	1565a785-dd3c-491c-94b3-93b12cd2e3a8	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:00:46.395472+00
83e66004-182f-4152-9643-2beb7e9cb546	fe67116b-0ad9-4491-9670-f40d1939db1e	f05bf03f-bfc2-41ec-8ea4-edef3bb79b36	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:00:46.395472+00
210d9df1-9e70-458e-bf6a-1f19d45ce54a	fe67116b-0ad9-4491-9670-f40d1939db1e	3fd49c1b-5f36-48fe-b2c0-4598653d28d8	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:13:00.533325+00
5c44e3e6-2986-4255-84b2-52f50907a225	fe67116b-0ad9-4491-9670-f40d1939db1e	1c115a56-9294-43e3-a446-f5084d0493e1	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:13:00.533325+00
07d687b8-3791-466d-ad40-97078541814b	fe67116b-0ad9-4491-9670-f40d1939db1e	9f4605c0-846f-478a-8015-622bcf2ece3a	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:20:48.004193+00
749a5e74-dd9c-47b9-97c7-56e43060b477	fe67116b-0ad9-4491-9670-f40d1939db1e	12ba7485-2a92-48c9-9f85-0f0966d0a1f1	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:20:48.004193+00
8fa15e57-ec1e-4dec-8bca-05450de41104	fe67116b-0ad9-4491-9670-f40d1939db1e	608d5f13-de80-4b55-a53a-fa7439dd558c	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:20:53.610046+00
e033eed0-22a4-44a0-94a2-1413629c61f7	fe67116b-0ad9-4491-9670-f40d1939db1e	cb0e26d1-a3ab-4551-8476-991a0940fe2e	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:20:53.610046+00
d7819ae6-5873-4997-8517-421fc7e5f1e1	fe67116b-0ad9-4491-9670-f40d1939db1e	756f24ca-6559-4339-a6c8-5e31e046c539	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:25:51.829511+00
c5759c85-0a42-44c7-9df6-c6f94cff2622	fe67116b-0ad9-4491-9670-f40d1939db1e	ef2f2ebd-44a9-4033-91d4-fc30a82ede72	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:25:51.829511+00
f343eee0-2c6a-4180-9e78-7373143b9a0f	fe67116b-0ad9-4491-9670-f40d1939db1e	a34ed4d8-46fc-47f8-8437-a3bfc394467c	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:27:40.543999+00
c7c9409e-5fd0-4670-9926-f6d0a12245ba	fe67116b-0ad9-4491-9670-f40d1939db1e	cee35d9f-9f7b-49a2-bb3e-bd96217b315c	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:27:40.543999+00
7d0d5bc2-ff62-4a2b-a770-81a94c0d36b5	fe67116b-0ad9-4491-9670-f40d1939db1e	0adcce70-6cfc-4238-a47c-3e2dd70b8fda	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:33:25.873823+00
24f0e4ed-c379-4737-aff6-d2696b485373	fe67116b-0ad9-4491-9670-f40d1939db1e	d58f61e0-bcbf-4ca5-b177-2728af21fbca	\N	\N	completed	13	\N	\N	{}	2026-02-16 19:33:25.873823+00
\.


--
-- Data for Name: generation_queue; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.generation_queue (id, user_id, type, prompt, settings, status, "position", priority, track_id, error_message, started_at, completed_at, created_at) FROM stdin;
\.


--
-- Data for Name: genre_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.genre_categories (id, name, name_ru, sort_order, created_at) FROM stdin;
999136eb-621c-4dec-b54f-efc74c6427a1	country	Кантри	1	2026-02-13 11:52:25.270167+00
a24400e0-77ac-4d55-b6b5-d115aa893482	dance	Танцевальная	2	2026-02-13 11:52:25.270167+00
7607a987-d0f6-4492-8ae7-9512f50c3bd8	downtempo	Даунтемпо	3	2026-02-13 11:52:25.270167+00
5068a357-73ae-403d-b399-77b7c841cb68	electronic	Электроника	4	2026-02-13 11:52:25.270167+00
f4fd0b56-64cf-452a-ac06-330301867c3b	funk	Фонк	5	2026-02-13 11:52:25.270167+00
646aafea-14e3-4c50-b6a8-12e227b4e5ea	jazz_soul	Джаз/Соул	6	2026-02-13 11:52:25.270167+00
68318043-afe3-49d7-9322-7291c0245949	latino	Латино	7	2026-02-13 11:52:25.270167+00
0d565264-08d9-4da1-9dd3-eccdfd05646c	reggae	Регги	8	2026-02-13 11:52:25.270167+00
6e97ca2a-534d-4ce1-92cb-4b658a9a7041	metal	Метал	9	2026-02-13 11:52:25.270167+00
9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	popular	Популярная	10	2026-02-13 11:52:25.270167+00
aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	rock	Рок	11	2026-02-13 11:52:25.270167+00
3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	urban	Урбан	12	2026-02-13 11:52:25.270167+00
\.


--
-- Data for Name: genres; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.genres (id, category_id, name, name_ru, sort_order, created_at) FROM stdin;
69b50ff2-d9f2-4e30-8f29-ad8db008f6e2	999136eb-621c-4dec-b54f-efc74c6427a1	appalachian	Аппалачская	1	2026-02-13 11:52:25.27244+00
9df23f43-1d39-4db1-bfa4-1aa1e8dcd4b9	999136eb-621c-4dec-b54f-efc74c6427a1	bluegrass	Блюграсс	2	2026-02-13 11:52:25.274901+00
9038145a-b737-496c-8d78-b66c1a6f1f38	999136eb-621c-4dec-b54f-efc74c6427a1	country	Кантри	3	2026-02-13 11:52:25.276223+00
a3e3b81a-112c-403e-8a8b-78e8eb438912	999136eb-621c-4dec-b54f-efc74c6427a1	folk	Фолк	4	2026-02-13 11:52:25.277511+00
8269cb5e-6fae-4d6a-98c1-03f61c5a549a	999136eb-621c-4dec-b54f-efc74c6427a1	freak_folk	Фрик-фолк	5	2026-02-13 11:52:25.280026+00
a6030015-2949-4115-aa23-bd58629d01c8	999136eb-621c-4dec-b54f-efc74c6427a1	western	Вестерн	6	2026-02-13 11:52:25.281348+00
a989be4b-d69c-4cf8-97dd-c54a754f4246	a24400e0-77ac-4d55-b6b5-d115aa893482	afro_cuban	Афро-кубинская	1	2026-02-13 11:52:25.282638+00
95318f88-bbfb-43c3-88a0-c5fca3fe165d	a24400e0-77ac-4d55-b6b5-d115aa893482	dance_pop	Дэнс-поп	2	2026-02-13 11:52:25.283916+00
504b0127-b13a-4d18-85ff-b9fb6dfffb03	a24400e0-77ac-4d55-b6b5-d115aa893482	disco	Диско	3	2026-02-13 11:52:25.285167+00
4c03954c-41b2-4b97-b607-ca64d6f91aeb	a24400e0-77ac-4d55-b6b5-d115aa893482	dubstep	Дабстеп	4	2026-02-13 11:52:25.286487+00
0a9c6b71-9175-4ce0-82ec-8be240f32afc	a24400e0-77ac-4d55-b6b5-d115aa893482	disco_funk	Диско-фанк	5	2026-02-13 11:52:25.288806+00
c8841179-2d80-46f6-93d6-93547350b123	a24400e0-77ac-4d55-b6b5-d115aa893482	edm	EDM	6	2026-02-13 11:52:25.29021+00
f244e34b-b66a-41cc-933c-824eecf40371	a24400e0-77ac-4d55-b6b5-d115aa893482	electro	Электро	7	2026-02-13 11:52:25.291495+00
9a907f84-099f-40e4-bb7e-a0aa433ee18b	a24400e0-77ac-4d55-b6b5-d115aa893482	hi_energy	Хай-энерджи	8	2026-02-13 11:52:25.292848+00
a27e463e-d923-43f0-8aec-1857b1d51e60	a24400e0-77ac-4d55-b6b5-d115aa893482	house	Хаус	9	2026-02-13 11:52:25.29431+00
ef3248de-ec25-4a9c-bf10-aa2a631c7c6e	a24400e0-77ac-4d55-b6b5-d115aa893482	trance	Транс	10	2026-02-13 11:52:25.295737+00
c34d9c21-2c1a-4b3e-bbc3-75d8532757b0	7607a987-d0f6-4492-8ae7-9512f50c3bd8	synthwave	Синтвейв	1	2026-02-13 11:52:25.297424+00
4b3a5f3f-b8a8-4433-90b3-30bcea9844c2	7607a987-d0f6-4492-8ae7-9512f50c3bd8	trap_downtempo	Трэп	2	2026-02-13 11:52:25.299226+00
8d4d052a-c61e-42e5-b1c4-07ecfee91459	5068a357-73ae-403d-b399-77b7c841cb68	ambient	Эмбиент	1	2026-02-13 11:52:25.300492+00
231aaee7-df09-4565-b1ea-2672d4fc2300	5068a357-73ae-403d-b399-77b7c841cb68	cyberpunk	Киберпанк	2	2026-02-13 11:52:25.301831+00
645c26fa-b52b-4545-bb4e-8ed16a87f615	5068a357-73ae-403d-b399-77b7c841cb68	drum_n_bass	Драм-н-бейс	3	2026-02-13 11:52:25.303232+00
d5a436d0-1b04-4eb1-a983-f2ef64e0974f	5068a357-73ae-403d-b399-77b7c841cb68	dubstep_electronic	Дабстеп	4	2026-02-13 11:52:25.304507+00
e840aa7f-e5dd-4d04-b5f7-63e3583b6707	5068a357-73ae-403d-b399-77b7c841cb68	hypnagogic	Гипнагогический	5	2026-02-13 11:52:25.306496+00
24f6a41b-d910-4cce-87bf-920168fbee54	5068a357-73ae-403d-b399-77b7c841cb68	idm	IDM	6	2026-02-13 11:52:25.308105+00
8393d790-f2da-4a4b-aa81-93ae7cd38048	f4fd0b56-64cf-452a-ac06-330301867c3b	synthpop	Синтпоп	1	2026-02-13 11:52:25.309954+00
8b10f70f-ea8a-446b-809a-820ec399a539	f4fd0b56-64cf-452a-ac06-330301867c3b	techno	Техно	2	2026-02-13 11:52:25.311294+00
da78eca1-ba97-4ad9-beab-2b7f1687ce47	f4fd0b56-64cf-452a-ac06-330301867c3b	trap_funk	Трэп	3	2026-02-13 11:52:25.312526+00
aaf1bec1-4053-4922-93d8-c7435841d025	646aafea-14e3-4c50-b6a8-12e227b4e5ea	jazz	Джаз	1	2026-02-13 11:52:25.313744+00
986184dc-fb4d-4f1c-ae8a-9aa6f493ff23	646aafea-14e3-4c50-b6a8-12e227b4e5ea	latin_jazz	Латино-джаз	2	2026-02-13 11:52:25.315339+00
dc41d2c7-164b-478d-ab00-5df4d13f7bec	646aafea-14e3-4c50-b6a8-12e227b4e5ea	rnb	Ритм-н-блюз (RnB)	3	2026-02-13 11:52:25.318298+00
e59d7cb7-4fb8-482b-ae0c-066a780afc68	646aafea-14e3-4c50-b6a8-12e227b4e5ea	soul	Соул	4	2026-02-13 11:52:25.319922+00
bfe71a2a-fbd3-44cd-903e-9ba37c2d1556	68318043-afe3-49d7-9322-7291c0245949	bossa_nova	Босса-нова	1	2026-02-13 11:52:25.321309+00
893b6cb8-e98b-4327-ba82-cbd99b3ab494	68318043-afe3-49d7-9322-7291c0245949	latin_jazz_latino	Латино-джаз	2	2026-02-13 11:52:25.322915+00
35b7b733-e570-4679-aec6-331d4b6511f6	68318043-afe3-49d7-9322-7291c0245949	forro	Форро	3	2026-02-13 11:52:25.324195+00
e4df0058-7170-4b56-b9b1-da3d4fdd8732	68318043-afe3-49d7-9322-7291c0245949	mambo	Мамбо	4	2026-02-13 11:52:25.325982+00
e98174f4-977c-4c43-8398-5c1b956b973a	68318043-afe3-49d7-9322-7291c0245949	salsa	Сальса	5	2026-02-13 11:52:25.327379+00
8ee4b6db-05e7-4b15-841d-b922258e4f5a	68318043-afe3-49d7-9322-7291c0245949	tango	Танго	6	2026-02-13 11:52:25.328609+00
faf9504c-f6b5-4568-8e25-43fe39b607fd	0d565264-08d9-4da1-9dd3-eccdfd05646c	afrobeat	Афробит	1	2026-02-13 11:52:25.329743+00
239b909e-1132-4d6f-b2e1-386e552c2768	0d565264-08d9-4da1-9dd3-eccdfd05646c	dancehall	Дэнсхолл	2	2026-02-13 11:52:25.330948+00
efe8f65e-a151-4ddd-9dea-3f5c7ff7ec91	0d565264-08d9-4da1-9dd3-eccdfd05646c	dub	Даб	3	2026-02-13 11:52:25.332175+00
854009d0-5652-438c-9996-9ba6f4b7b3f5	0d565264-08d9-4da1-9dd3-eccdfd05646c	reggae	Регги	4	2026-02-13 11:52:25.333753+00
14badc5d-783c-4580-956f-e20c6dbe0e80	0d565264-08d9-4da1-9dd3-eccdfd05646c	reggaeton	Реггетон	5	2026-02-13 11:52:25.335184+00
a77832b7-5288-4125-a54d-c1e19cfdb5e1	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	black_metal	Блэк-метал	1	2026-02-13 11:52:25.337022+00
17d559d4-a8c2-4278-95f8-c94454ba30cd	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	deathcore	Дэткор	2	2026-02-13 11:52:25.338583+00
2a2daec4-7f00-4e01-ad6b-6090774ff162	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	death_metal	Дэт-метал	3	2026-02-13 11:52:25.339837+00
f72b1f51-a4a7-4cbb-9d93-dd61340a3f5e	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	heavy_metal	Хэви-метал	4	2026-02-13 11:52:25.341098+00
98b6ff8f-9e21-41e5-9fdc-199e37801b21	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	heavy_metal_trap	Хэви-метал трэп	5	2026-02-13 11:52:25.34263+00
e37e9b90-d293-47e7-acb3-a8e4ca11ace8	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	metalcore	Металкор	6	2026-02-13 11:52:25.343837+00
77a0ff57-dd04-4770-84fa-3ea495715651	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	nu_metal	Ню-метал	7	2026-02-13 11:52:25.345052+00
4ac1836d-23e2-4a37-aa63-48e1708364cd	6e97ca2a-534d-4ce1-92cb-4b658a9a7041	power_metal	Пауэр-метал	8	2026-02-13 11:52:25.346321+00
67430ce4-0eed-4625-b74c-1e9cc6d8fd20	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	pop	Поп	1	2026-02-13 11:52:25.348024+00
c9326786-f706-4b2b-aa1b-e2f58fd6e92b	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	dance_pop_popular	Дэнс-поп	2	2026-02-13 11:52:25.349255+00
c32401d5-a08c-4b37-8b84-0fb73a0ac290	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	pop_rock	Поп-рок	3	2026-02-13 11:52:25.350928+00
8e850619-f86e-45e8-9bcc-9da271cc2988	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	k_pop	К-поп	4	2026-02-13 11:52:25.352173+00
57d67069-18fa-45bc-8fee-c2707998957c	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	j_pop	Джей-поп	5	2026-02-13 11:52:25.353541+00
2788c50f-0e92-4104-9530-bd8062d39d92	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	rnb_popular	Ритм-н-блюз	6	2026-02-13 11:52:25.355058+00
91689943-04f1-4b05-8b80-e21d6bf2d015	9b8c47e2-df8b-47d9-88fa-6319b89d1dd6	synthpop_popular	Синтпоп	7	2026-02-13 11:52:25.357286+00
b2ed2a93-a083-4e35-8628-47b91fa39530	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	classic_rock	Классический рок	1	2026-02-13 11:52:25.358621+00
bef413d9-e67e-43ee-9718-24233dfe0055	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	blues_rock	Блюз-рок	2	2026-02-13 11:52:25.360266+00
35fa7239-3559-4741-8f22-6b15e932a474	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	emo	Эмо	3	2026-02-13 11:52:25.361589+00
a8017a1f-04de-4eea-9a1c-545c38d74337	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	glam_rock	Глэм-рок	4	2026-02-13 11:52:25.363141+00
6219ebad-36d1-40f4-a8d6-134bf9b90118	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	hardcore_punk	Хардкор панк	5	2026-02-13 11:52:25.364425+00
2b099e7a-f5db-442d-b2ac-b87dd9d1eaa9	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	indie	Инди	6	2026-02-13 11:52:25.365884+00
bf669d48-183f-4710-9d80-c9cb2f3b9233	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	industrial_rock	Индастриал рок	7	2026-02-13 11:52:25.367179+00
7d2ebe09-0eb5-4d1b-bc58-63cdfbf93ffd	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	punk	Панк	8	2026-02-13 11:52:25.368848+00
21808a32-f344-4703-88d6-798bee21956a	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	rock_general	Рок	9	2026-02-13 11:52:25.370521+00
885b987c-3078-418c-a513-9889fe7fce47	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	skate_rock	Скейт-рок	10	2026-02-13 11:52:25.371959+00
ce793e6c-8af4-4f46-afda-d2e94f31431c	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	skatecore	Скейткор	11	2026-02-13 11:52:25.373597+00
e8623d7d-277e-486d-99f5-cd695a3126a2	aa1c5872-2a2e-4b14-a5f2-db4b431bfff5	suomipop	Суомипоп	12	2026-02-13 11:52:25.375216+00
6763be01-671c-44a3-a08f-da8096e0104d	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	phonk	Фанк	1	2026-02-13 11:52:25.376501+00
af159085-a109-492d-8100-7a583275442a	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	electro_urban	Электро	2	2026-02-13 11:52:25.377874+00
1fdd33b5-8055-48be-86be-64ef2be69a93	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	hip_hop	Хип-хоп	3	2026-02-13 11:52:25.379694+00
b635a979-b114-4580-bdee-fb36a033cd4a	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	rnb_urban	РнБ	4	2026-02-13 11:52:25.381219+00
ecfc90cd-274a-4be3-b87c-e655ddf30f76	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	phonk_urban	Фонк	5	2026-02-13 11:52:25.382765+00
6573feb7-a3bf-44da-8998-44ea87c8e012	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	rap	Рэп	6	2026-02-13 11:52:25.383946+00
f1126c2d-58cd-46c5-90d5-5fae467e2162	3ad27dd8-688b-4d32-88dc-d3f474e8b0c5	trap	Трэп	7	2026-02-13 11:52:25.385335+00
\.


--
-- Data for Name: impersonation_action_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.impersonation_action_logs (id, admin_id, target_user_id, action, details, created_at) FROM stdin;
\.


--
-- Data for Name: internal_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.internal_votes (id, track_id, user_id, vote, comment, created_at) FROM stdin;
\.


--
-- Data for Name: item_purchases; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.item_purchases (id, item_id, buyer_id, seller_id, price, status, created_at) FROM stdin;
\.


--
-- Data for Name: legal_documents; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.legal_documents (id, type, title, content, version, is_active, published_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: lyrics; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.lyrics (id, user_id, title, content, genre, mood, language, is_public, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: lyrics_deposits; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.lyrics_deposits (id, user_id, lyrics_item_id, amount, status, created_at) FROM stdin;
\.


--
-- Data for Name: lyrics_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.lyrics_items (id, user_id, title, content, genre, mood, tags, price, is_public, downloads_count, created_at, updated_at, description, genre_id, is_active, is_exclusive, is_for_sale, language, license_type, sales_count, track_id, views_count) FROM stdin;
\.


--
-- Data for Name: maintenance_whitelist; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.maintenance_whitelist (id, user_id, created_at) FROM stdin;
53f36d7e-2667-4942-a0a4-22ede428e8e3	a0000000-0000-0000-0000-000000000001	2026-02-13 12:07:53.823488+00
8b2be237-a7b4-40bb-b550-5902a52c892b	fe67116b-0ad9-4491-9670-f40d1939db1e	2026-02-15 17:09:29.745197+00
d21d01fa-ede2-4721-927e-8fa007d10654	955ff6c1-f3db-4087-8e68-cb67ffc41862	2026-02-15 18:38:10.437606+00
9dbb402f-12b0-4fd1-9a4d-743fc7891dad	577de5d6-c06e-4583-9631-9817db23b84d	2026-02-15 21:58:16.715452+00
\.


--
-- Data for Name: message_reactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.message_reactions (id, message_id, user_id, emoji, conversation_id, created_at) FROM stdin;
\.


--
-- Data for Name: messages; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.messages (id, sender_id, receiver_id, content, attachment_url, is_read, created_at, conversation_id, attachment_type, forwarded_from_id, deleted_at, updated_at) FROM stdin;
390bdbc2-80ca-414f-9b08-3ba6624513b1	a0000000-0000-0000-0000-000000000001	\N	фЫвфывыв	\N	f	2026-02-14 21:47:05.574639+00	21a7be3c-3bfa-4d89-94fa-9ed8b299127e	\N	\N	\N	2026-02-14 21:47:05.574639+00
1220c5f5-07e5-4e89-bbcc-983f65232f5a	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	фывфывФЫВ	\N	f	2026-02-14 21:47:15.818483+00	21a7be3c-3bfa-4d89-94fa-9ed8b299127e	\N	\N	\N	2026-02-14 21:47:15.818483+00
e6269b85-5752-4d23-aa3a-4a8ee8456161	a0000000-0000-0000-0000-000000000001	\N	ЫВМЫВФЫ	\N	f	2026-02-14 21:47:25.575597+00	21a7be3c-3bfa-4d89-94fa-9ed8b299127e	\N	\N	\N	2026-02-14 21:47:25.575597+00
52e9ba44-5009-44df-a5f6-798572bca0b7	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	ФЫВАЫФВАЫФВ	\N	f	2026-02-14 21:47:28.86746+00	21a7be3c-3bfa-4d89-94fa-9ed8b299127e	\N	\N	\N	2026-02-14 21:47:28.86746+00
1940e6a2-bdef-4f73-9d09-89bc9271e655	a0000000-0000-0000-0000-000000000001	\N	ВАЫФВАФЫВА	\N	f	2026-02-14 21:49:25.892651+00	65a1f411-f756-4d50-93fc-d6a4c03fa743	\N	\N	\N	2026-02-14 21:49:25.892651+00
189903fd-2ed8-46a0-9193-9328ce94174b	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	ЫФАФЫВАФЫВА	\N	f	2026-02-14 21:49:36.233083+00	65a1f411-f756-4d50-93fc-d6a4c03fa743	\N	\N	\N	2026-02-14 21:49:36.233083+00
1166aa74-ba67-489c-bea1-017f4fac631f	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	ФЫВАЫФВАФ	\N	f	2026-02-14 21:49:45.524743+00	65a1f411-f756-4d50-93fc-d6a4c03fa743	\N	\N	\N	2026-02-14 21:49:45.524743+00
67c91ada-02d6-45f2-aa16-83ccfe4547fa	a0000000-0000-0000-0000-000000000001	\N	ыфваыфвафыва	\N	f	2026-02-14 21:58:30.331554+00	38737d04-e5bc-45dc-814b-9f7d1939c12e	\N	\N	\N	2026-02-14 21:58:30.331554+00
da11ab99-b6f2-40e5-b747-799098ee09cb	a0000000-0000-0000-0000-000000000001	\N	вафывафывафывафыв	\N	f	2026-02-14 22:01:16.2418+00	1c23111d-6cd4-4a31-8d62-766c1e491943	\N	\N	\N	2026-02-14 22:01:16.2418+00
a14613bc-6c3f-4d61-b45c-77daa1527aaa	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	фывафывафыв	\N	f	2026-02-14 22:01:26.447384+00	1c23111d-6cd4-4a31-8d62-766c1e491943	\N	\N	\N	2026-02-14 22:01:26.447384+00
cb8e406d-7da6-4249-9307-ccf447e72428	a0000000-0000-0000-0000-000000000001	\N	фывафывафы	\N	f	2026-02-14 22:01:33.97423+00	1c23111d-6cd4-4a31-8d62-766c1e491943	\N	\N	\N	2026-02-14 22:01:33.97423+00
a662efe5-61fc-48e0-a7d3-9e9d9775ac61	a0000000-0000-0000-0000-000000000001	\N	афывафыва	\N	f	2026-02-14 22:03:04.586083+00	8f07b3da-ed4a-44ea-91a6-dfbb61bd15f5	\N	\N	\N	2026-02-14 22:03:04.586083+00
d0812059-b0c7-4cba-85b3-71e602b448ab	a0000000-0000-0000-0000-000000000001	\N	dfsadfasdf	\N	f	2026-02-14 22:42:56.642899+00	c7f73997-c505-426a-bf88-226fe4b40e8e	\N	\N	\N	2026-02-14 22:42:56.642899+00
\.


--
-- Data for Name: moderator_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.moderator_permissions (id, user_id, category_id, can_edit, can_delete, can_ban, granted_by, created_at) FROM stdin;
\.


--
-- Data for Name: moderator_presets; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.moderator_presets (id, name, permissions, created_at, name_ru, description, category_ids, is_active, sort_order) FROM stdin;
daa39312-28c7-42cb-b334-a59a6bcf4cf3	Content Moderator	[]	2026-02-15 17:59:12.551346+00	Контент-модератор	Модерация загруженных треков и авторских прав	{9df9b28f-dc08-42e8-9fe9-c6b6b7866520,29ae121a-49be-4892-a987-7f13da9aae83}	t	1
1af53f38-eb1e-4507-adec-2bc9a7e7a616	Forum Moderator	[]	2026-02-15 17:59:12.551346+00	Форум-модератор	Модерация форума, баны, предупреждения	{6e2d64f0-79fe-4694-88f8-bb3f935abffb,1c9e2f96-09d9-4d52-b150-dd86b3a1def3}	t	2
16100167-9e8f-4a58-9c2d-48e3a42043db	Full Moderator	[]	2026-02-15 17:59:12.551346+00	Полный модератор	Все функции модерации контента и форума	{9df9b28f-dc08-42e8-9fe9-c6b6b7866520,29ae121a-49be-4892-a987-7f13da9aae83,6e2d64f0-79fe-4694-88f8-bb3f935abffb,1c9e2f96-09d9-4d52-b150-dd86b3a1def3}	t	3
cbc015f6-730a-4073-959c-dd43317cbf9f	Community Manager	[]	2026-02-15 17:59:12.551346+00	Комьюнити-менеджер	Форум, поддержка, мероприятия, коммуникации	{6e2d64f0-79fe-4694-88f8-bb3f935abffb,1c9e2f96-09d9-4d52-b150-dd86b3a1def3,dfc85f7e-b2c9-4581-877c-0f1940d63c44,5188985e-f109-4512-b505-2792d3443cfb}	t	4
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.notifications (id, user_id, type, title, message, data, is_read, created_at, actor_id, link, metadata, target_id, target_type) FROM stdin;
fc2bcc4d-de5f-4ed1-b332-13379650f033	955ff6c1-f3db-4087-8e68-cb67ffc41862	track_approved	Трек одобрен!	Ваш трек "Тест редактора" прошёл модерацию и опубликован в каталоге. Отправьте его на дистрибуцию через SILK, чтобы он появился на Spotify, Apple Music и VK Music!	{}	t	2026-02-14 23:17:15.877356+00	\N	\N	{}	376aa628-eafd-48a3-9d11-f46e81c99eb3	track
f552a7d5-84e8-40e5-bcbd-99711ac431a7	955ff6c1-f3db-4087-8e68-cb67ffc41862	refund	Ошибка: Внутренняя ошибка сервера	Произошла внутренняя ошибка на сервере Suno. Попробуйте позже.\n\nВам возвращено 5 ₽	{}	t	2026-02-14 23:33:00.841538+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	track
d43c6988-f0ad-41e0-ab39-50d397a395e3	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Поздравляем с назначением на роль «Администратор»!	Вы успешно приняли роль «Администратор». Новые инструменты уже доступны. Используйте их ответственно!	{}	t	2026-02-15 17:35:43.963071+00	a0000000-0000-0000-0000-000000000001	\N	{}	00385b8e-1f8b-4d53-b33a-9a3bc65f6150	role_invitation
e9f208be-aa23-491c-ad1f-e9ff9d9a939e	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Роль «Администратор» снята	Ваша роль «Администратор» была снята администрацией платформы.	{}	t	2026-02-15 18:05:55.111873+00	a0000000-0000-0000-0000-000000000001	\N	{}	955ff6c1-f3db-4087-8e68-cb67ffc41862	role_revocation
f107410b-3a1d-4071-93c3-b405737e06ce	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	✅ Трек одобрен для дистрибуции!	Поздравляем! Трек "Черновик 1 (v2)" прошёл модерацию. Загрузите Master-копию в формате WAV 24-bit для перехода на Level Pro.	{}	t	2026-02-15 20:12:14.526958+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	distribution
f295cbf2-e8af-4340-9f1a-93daf876bf00	a0000000-0000-0000-0000-000000000001	role_accepted	Приглашение на роль "Администратор" принято	Пользователь принял приглашение и получил назначенную роль	{}	t	2026-02-15 17:35:43.945148+00	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	{}	00385b8e-1f8b-4d53-b33a-9a3bc65f6150	role_invitation
6a08172e-58ce-4ceb-b746-6f3f0fb4fb18	a0000000-0000-0000-0000-000000000001	role_accepted	Приглашение на роль "Администратор" принято	Пользователь принял приглашение и получил назначенную роль	{}	t	2026-02-15 18:01:04.107504+00	fe67116b-0ad9-4491-9670-f40d1939db1e	\N	{}	678ffa2c-2ca8-4b4b-b8ae-722df3df3d23	role_invitation
f0f7c5a2-3965-48cc-917e-3197ceb2932e	955ff6c1-f3db-4087-8e68-cb67ffc41862	verification_approved	?????????????????????? ????????????????????????	??????????????????????! ?????? ?????????????? ?????????????? ???????????? ??????????.	{}	t	2026-02-15 19:04:28.337415+00	a0000000-0000-0000-0000-000000000001	\N	{}	f9c120e9-5d8f-4305-9eb0-85617f1ed424	verification
cd7346b1-f0da-488e-b31a-2d43c5f65b2b	a0000000-0000-0000-0000-000000000001	role_accepted	Приглашение на роль "Администратор" принято	Пользователь принял приглашение и получил назначенную роль	{}	t	2026-02-15 22:02:16.270729+00	577de5d6-c06e-4583-9631-9817db23b84d	\N	{}	d362d0bf-679b-4638-b54c-e164f7ccd8cd	role_invitation
12bbb4bd-bd6e-41e1-b08c-ca9863e9ee16	577de5d6-c06e-4583-9631-9817db23b84d	verification_approved	?????????????????????? ????????????????????????	??????????????????????! ?????? ?????????????? ?????????????? ???????????? ??????????????.	{}	t	2026-02-15 23:21:15.127856+00	a0000000-0000-0000-0000-000000000001	\N	{}	2254eb27-c463-44b6-9e71-f7cdf61d8ea4	verification
baa69340-94de-470e-8a29-96f8425e54d3	a0000000-0000-0000-0000-000000000001	achievement	Достижение разблокировано!	👑 Легенда	{"icon": "👑", "xp_reward": 500, "credit_reward": 200, "achievement_key": "legend", "achievement_name": "Легенда"}	f	2026-02-16 01:33:44.8428+00	\N	\N	{}	\N	\N
cc69457d-2abe-4d93-a22a-4c969191230a	a0000000-0000-0000-0000-000000000001	role_accepted	Приглашение на роль "Администратор" принято	Пользователь принял приглашение и получил назначенную роль	{}	f	2026-02-16 10:39:35.233169+00	955ff6c1-f3db-4087-8e68-cb67ffc41862	\N	{}	bd216ba9-b338-4705-8936-208748f69717	role_invitation
bc96c142-b6d0-4234-9c57-23bdf7625c31	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	❌ Ошибка анализа	Не удалось проанализировать мастер-файл для трека "Черновик 1 (v2)". Попробуйте позже или загрузите файл повторно.	{}	t	2026-02-15 20:18:17.279147+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	track
55a659d6-fdaa-4c60-af26-82ea706bbbb0	955ff6c1-f3db-4087-8e68-cb67ffc41862	achievement	Достижение разблокировано!	👑 Легенда	{"icon": "👑", "xp_reward": 500, "credit_reward": 200, "achievement_key": "legend", "achievement_name": "Легенда"}	t	2026-02-16 01:32:33.058835+00	\N	\N	{}	\N	\N
94d6987f-c934-4c06-ac22-ac83eb457bea	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	❌ Ошибка анализа	Не удалось проанализировать мастер-файл для трека "Черновик 1 (v2)". Попробуйте позже или загрузите файл повторно.	{}	t	2026-02-15 20:37:24.054285+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	track
97d55ae9-56f9-48a9-bd36-6b367e6410b9	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	❌ Ошибка анализа	Не удалось проанализировать мастер-файл для трека "Черновик 1 (v2)". Попробуйте позже или загрузите файл повторно.	{}	t	2026-02-15 20:50:07.751044+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	track
ac598409-8e76-4905-a0c1-dc13ac370e77	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	🎉 Золотой пакет готов!	Трек "Черновик 1 (v2)" полностью обработан. WAV (-14 LUFS), XML-метаданные, сертификат и OTS-доказательство доступны для скачивания.	{}	t	2026-02-15 21:02:11.833178+00	\N	\N	{}	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	track
92c8771b-2fe6-4da0-bd6c-ac4a85f08daf	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Депонирование завершено	Трек "undefined" успешно депонирован	{}	t	2026-02-15 21:46:42.013011+00	\N	\N	{}	666e95a3-d230-42d0-87ce-3081a0cc299d	track
4d3b9e36-d044-4f4f-8b4d-069e754a8c31	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Депонирование завершено	Трек "undefined" успешно депонирован	{}	t	2026-02-15 22:00:56.975989+00	\N	\N	{}	a90a39d1-7041-40c5-9ec1-c3984a962df3	track
84440373-f761-48b4-b1a1-6600de5e74df	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Депонирование завершено	Трек "undefined" успешно депонирован	{}	t	2026-02-15 22:10:58.305967+00	\N	\N	{}	62ba5a2a-20e6-4cff-bd09-1e5da9459cab	track
01d59d9c-a9c9-43e0-8e40-89cf7bfaa9d4	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Депонирование завершено	Трек "undefined" успешно депонирован	{}	t	2026-02-15 22:21:49.718888+00	\N	\N	{}	fc7b314a-bc3b-4dca-b852-3ce42a10b4f9	track
d479f5ca-05a1-47b8-83a7-eaf14bbb31c4	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Депонирование завершено	Трек "undefined" успешно депонирован	{}	t	2026-02-15 23:05:24.737075+00	\N	\N	{}	38f07fea-ea94-4072-ae24-ac6bb45308cf	track
bc4d29ab-2adc-4253-b208-31dcf64827f7	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Поздравляем с назначением на роль «Администратор»!	Вы успешно приняли роль «Администратор». Новые инструменты уже доступны. Используйте их ответственно!	{}	t	2026-02-16 10:39:35.246397+00	a0000000-0000-0000-0000-000000000001	\N	{}	bd216ba9-b338-4705-8936-208748f69717	role_invitation
5e9887a2-ee10-4b6e-ac24-feb73cfc540a	955ff6c1-f3db-4087-8e68-cb67ffc41862	system	Роль «Администратор» снята	Ваша роль «Администратор» была снята администрацией платформы.	{}	t	2026-02-16 10:40:28.458145+00	a0000000-0000-0000-0000-000000000001	\N	{}	955ff6c1-f3db-4087-8e68-cb67ffc41862	role_revocation
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payments (id, user_id, amount, currency, status, provider, provider_payment_id, description, metadata, created_at, updated_at, external_id, payment_system) FROM stdin;
1b4dcadd-539c-4ba4-a039-02c602413054	a0000000-0000-0000-0000-000000000001	5000	RUB	pending	\N	\N	Пополнение баланса на 5000 ₽	{}	2026-02-16 01:36:32.47433+00	2026-02-16 01:36:32.47433+00	\N	yookassa
\.


--
-- Data for Name: payout_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payout_requests (id, seller_id, amount, payment_method, payment_details, status, processed_at, processed_by, notes, created_at) FROM stdin;
\.


--
-- Data for Name: performance_alerts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.performance_alerts (id, metric, value, threshold, severity, context, resolved, created_at) FROM stdin;
\.


--
-- Data for Name: permission_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.permission_categories (id, name, slug, description, sort_order, created_at, key, name_ru, is_active, icon) FROM stdin;
60a0a50d-ce33-4f22-b254-53b16d66ddb2	Users	\N	Управление пользователями, верификация, блокировки	1	2026-02-15 18:00:09.207794+00	users	Пользователи	t	Users
9df9b28f-dc08-42e8-9fe9-c6b6b7866520	Moderation	\N	Модерация треков, голосование, авторские права	2	2026-02-15 18:00:09.207794+00	moderation	Модерация	t	Shield
29ae121a-49be-4892-a987-7f13da9aae83	Tracks	\N	Просмотр и управление всеми треками	3	2026-02-15 18:00:09.207794+00	tracks	Треки	t	Music
6e2d64f0-79fe-4694-88f8-bb3f935abffb	Forum	\N	Модерация форума, баны, варнинги, категории	4	2026-02-15 18:00:09.207794+00	forum	Форум	t	MessageSquare
1c9e2f96-09d9-4d52-b150-dd86b3a1def3	Support	\N	Тикеты поддержки и баг-репорты	5	2026-02-15 18:00:09.207794+00	support	Поддержка	t	Headset
dfc85f7e-b2c9-4581-877c-0f1940d63c44	Events	\N	Конкурсы и объявления	6	2026-02-15 18:00:09.207794+00	events	Мероприятия	t	Award
7fd9cf13-578c-4134-b211-8ecb2978eaa0	Economy	\N	Баланс, XP, реферальная система	7	2026-02-15 18:00:09.207794+00	economy	Экономика	t	DollarSign
485ea1c6-3df8-4911-8f48-a76ede75cad3	Revenue	\N	Подписки, реклама, депозиты	8	2026-02-15 18:00:09.207794+00	revenue	Монетизация	t	TrendingUp
b3f58f4d-07eb-46f2-8779-38c415318dc4	Catalog	\N	Жанры, стили, модели, шаблоны	9	2026-02-15 18:00:09.207794+00	catalog	Справочники	t	Database
f42d7863-3125-4f50-a92a-2df31cd17255	Feed	\N	Настройка алгоритма умной ленты	10	2026-02-15 18:00:09.207794+00	feed	Лента	t	Activity
3c0d4e3a-54c5-450e-9f76-525d505bbcb7	Radio	\N	Управление радио, аукцион, Listen-to-Earn	11	2026-02-15 18:00:09.207794+00	radio	Радио	t	Radio
5188985e-f109-4512-b505-2792d3443cfb	Communications	\N	Email-рассылки и push-уведомления	12	2026-02-15 18:00:09.207794+00	communications	Коммуникации	t	Send
fd8e4161-d235-476c-91d4-349a94373251	System	\N	Системные настройки, AI, логи, техработы	13	2026-02-15 18:00:09.207794+00	system	Система	t	Settings
\.


--
-- Data for Name: personas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.personas (id, user_id, name, description, avatar_url, voice_style, settings, is_public, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: playlist_tracks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.playlist_tracks (id, playlist_id, track_id, "position", added_at) FROM stdin;
\.


--
-- Data for Name: playlists; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.playlists (id, user_id, title, description, cover_url, is_public, tracks_count, created_at, updated_at, likes_count, plays_count) FROM stdin;
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.profiles (id, user_id, username, avatar_url, balance, created_at, updated_at, display_name, role, is_super_admin, is_protected, bio, subscription_type, subscription_expires_at, email, generation_count, total_likes, followers_count, following_count, tracks_count, is_verified, onboarding_completed, ad_free_until, is_blocked, blocked_at, blocked_reason, blocked_by, referral_code, referred_by, cover_url, social_links, notification_settings, email_unsubscribed, short_id, last_seen_at, xp, level, trust_level, specialty, ad_free_purchased_at, contest_participations, contest_wins, contest_wins_count, email_last_changed_at, total_prize_won, verification_type, verified_at, verified_by, credits, contests_entered, contests_won) FROM stdin;
17129225-7a09-409b-91b2-05d9c473a920	a0000000-0000-0000-0000-000000000001	AI Planet Sound	https://aimuza.ru/storage/v1/object/public/avatars/a0000000-0000-0000-0000-000000000001/avatar-1771092562043.jpg	2997	2026-02-13 12:06:38.837303+00	2026-02-16 23:48:23.429352+00	AI Planet Sound	superadmin	t	t	\N	premium	\N	\N	0	0	0	0	0	t	t	\N	f	\N	\N	\N	\N	\N	https://aimuza.ru/storage/v1/object/public/covers/a0000000-0000-0000-0000-000000000001/cover-1771092565791.jpg	{}	{}	f	\N	2026-02-16 23:48:23.429352+00	0	1	0	РўРµС…РЅРёС‡РµСЃРєРёР№ СЃРїРµС†РёР°Р»РёСЃС‚	\N	0	[]	0	\N	0	\N	\N	\N	200	0	0
e28888ba-0138-42a5-875b-afb6caf224c0	fe67116b-0ad9-4491-9670-f40d1939db1e	Золотинка	https://aimuza.ru/storage/v1/object/public/avatars/fe67116b-0ad9-4491-9670-f40d1939db1e/avatar-1771175934779.jpg	8844	2026-02-15 17:06:03.798788+00	2026-02-17 14:35:42.944628+00	Золотинка	admin	f	f	Автор-исполнитель	free	\N	vladavershininaavtor@yandex.ru	0	0	0	0	0	t	t	\N	f	\N	\N	\N	\N	\N	https://aimuza.ru/storage/v1/object/public/covers/fe67116b-0ad9-4491-9670-f40d1939db1e/cover-1771175934830.jpg	{}	{}	f	\N	2026-02-17 14:35:42.944628+00	0	1	0		\N	0	[]	0	\N	0	artist	2026-02-15 19:10:53.221987+00	a0000000-0000-0000-0000-000000000001	0	0	0
6f1d35f6-07fa-4c5d-b8f5-d902a40ced9c	577de5d6-c06e-4583-9631-9817db23b84d	Swede St	https://aimuza.ru/storage/v1/object/public/avatars/577de5d6-c06e-4583-9631-9817db23b84d/avatar-1771197490748.jpg	592	2026-02-15 21:56:54.572679+00	2026-02-15 23:22:34.29419+00	Swede	admin	f	f	\N	free	\N	shvedov@bk.ru	0	0	0	0	0	t	t	\N	f	\N	\N	\N	\N	\N	\N	{}	{}	f	\N	2026-02-15 23:22:34.29419+00	0	1	0		\N	0	[]	0	\N	0	partner	2026-02-15 23:21:15.127856+00	a0000000-0000-0000-0000-000000000001	0	0	0
52a0a199-e0ab-4673-ad98-8a0873879a58	955ff6c1-f3db-4087-8e68-cb67ffc41862	Страдалец	\N	5535	2026-02-14 19:12:09.051637+00	2026-02-16 10:39:35.218036+00	Страдалец	admin	f	f	\N	free	\N	shvedov.roman@mail.ru	0	0	0	0	0	t	t	\N	f	\N	\N	\N	\N	\N	\N	{}	{}	f	\N	2026-02-16 10:39:04.682362+00	0	1	0		\N	0	[]	0	\N	0	artist	2026-02-15 19:04:28.337415+00	a0000000-0000-0000-0000-000000000001	200	0	0
\.


--
-- Data for Name: promo_videos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.promo_videos (id, user_id, track_id, title, video_url, thumbnail_url, status, is_public, views_count, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: prompt_purchases; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.prompt_purchases (id, buyer_id, prompt_id, seller_id, price, payment_id, status, created_at) FROM stdin;
\.


--
-- Data for Name: prompts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.prompts (id, user_id, title, description, prompt_text, genre, tags, price, is_public, uses_count, rating, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: qa_bounties; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_bounties (id, title, description, category, severity_min, reward_xp, reward_credits, max_claims, claimed_count, is_active, expires_at, created_by, created_at) FROM stdin;
b491e0b2-5433-49e4-8054-4ef92691ed48	Critical Bug Bounty	Find critical bugs affecting core functionality. 100 XP + 30 credits per confirmed report.	\N	critical	100	30	50	0	t	\N	d899d095-eb16-4429-923e-dcfdf965e493	2026-02-14 11:32:40.493654+00
\.


--
-- Data for Name: qa_comments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_comments (id, ticket_id, user_id, message, is_staff, is_system, attachments, created_at) FROM stdin;
3b8da2af-fb0e-4c90-a7be-ff5472dc8f6f	1f42bae8-d081-4c46-acc9-f04c7585fdc2	a0000000-0000-0000-0000-000000000001	мыаыпывапывап	f	f	\N	2026-02-14 15:14:34.679847+00
77a22e3d-4a7c-4b1e-b517-b438b2b11524	1f42bae8-d081-4c46-acc9-f04c7585fdc2	a0000000-0000-0000-0000-000000000001	ывапывапывап	f	f	\N	2026-02-14 15:14:37.581743+00
c0c38e9e-1860-42fc-8525-9f3c8d3b4c81	f13f18f8-5a35-4291-b479-d68f4e53caa2	a0000000-0000-0000-0000-000000000001	Статус изменён на new. 	t	t	\N	2026-02-15 18:11:26.615553+00
63a0df24-52ae-45b5-b191-e63c716560ab	8db18bd5-f4d9-4b56-8167-04c6f460515a	a0000000-0000-0000-0000-000000000001	Статус изменён на confirmed. 	t	t	\N	2026-02-15 23:07:17.628938+00
46531b30-4598-45f8-8886-b006f01da40c	f13f18f8-5a35-4291-b479-d68f4e53caa2	a0000000-0000-0000-0000-000000000001	Статус изменён на confirmed. 	t	t	\N	2026-02-15 23:08:49.905797+00
88592327-8bab-4552-976a-e6e0486d2385	a37355c0-764c-4204-a733-ed5eacfe7ba5	a0000000-0000-0000-0000-000000000001	???????????? ?????????????? ???? confirmed. 	t	t	\N	2026-02-15 23:34:39.371632+00
7599ebe7-8f52-40c7-9bcb-faaf3b2a7edf	86275204-c706-45be-bba6-2425a4caca93	a0000000-0000-0000-0000-000000000001	???????????? ?????????????? ???? new. 	t	t	\N	2026-02-15 23:49:15.178929+00
39ab0bb3-397f-452d-bd3d-6855a524d4b0	86275204-c706-45be-bba6-2425a4caca93	a0000000-0000-0000-0000-000000000001	???????????? ?????????????? ???? confirmed. 	t	t	\N	2026-02-15 23:49:59.937962+00
\.


--
-- Data for Name: qa_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_config (key, value, label, description, updated_at) FROM stdin;
general	{"auto_triage": true, "dedup_threshold": 0.35, "cooldown_minutes": 5, "max_reports_per_day": 10, "confirmation_threshold": 3, "min_description_length": 30}	General Settings	Core QA system parameters	2026-02-14 11:32:05.356742+00
tiers	{"core_qa": {"label": "Core QA", "vote_weight": 2.0, "min_accuracy": 0.8, "min_confirmed": 20}, "bug_hunter": {"label": "Bug Hunter", "vote_weight": 1.5, "min_accuracy": 0.6, "min_confirmed": 5}, "contributor": {"label": "Contributor", "vote_weight": 1.0, "min_accuracy": 0, "min_confirmed": 0}}	Tester Tiers	Tier requirements and weights	2026-02-14 11:32:05.356742+00
rewards	{"vote_xp": 2, "major_xp": 25, "minor_xp": 10, "blocker_xp": 100, "cosmetic_xp": 5, "critical_xp": 50, "major_credits": 5, "minor_credits": 0, "blocker_credits": 30, "cosmetic_credits": 0, "critical_credits": 15}	Reward Settings	XP and credit rewards by severity	2026-02-14 11:32:05.356742+00
categories	{"ui": {"icon": "Palette", "color": "pink", "label": "UX / Design"}, "audio": {"icon": "Headphones", "color": "orange", "label": "Audio / Player"}, "other": {"icon": "HelpCircle", "color": "gray", "label": "Other"}, "backend": {"icon": "Server", "color": "green", "label": "Backend / API"}, "ai_model": {"icon": "Cpu", "color": "purple", "label": "AI Model"}, "frontend": {"icon": "Monitor", "color": "blue", "label": "Frontend / UI"}, "security": {"icon": "Shield", "color": "red", "label": "Security"}, "performance": {"icon": "Zap", "color": "yellow", "label": "Performance"}}	Categories	Ticket category definitions	2026-02-14 11:32:05.356742+00
\.


--
-- Data for Name: qa_tester_stats; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_tester_stats (user_id, tier, reports_total, reports_confirmed, reports_rejected, reports_critical, votes_cast, accuracy_rate, xp_earned, credits_earned, streak_days, best_streak, last_report_at, tier_updated_at, created_at) FROM stdin;
a0000000-0000-0000-0000-000000000001	contributor	1	0	0	0	0	0	0	0	0	0	2026-02-14 16:08:52.714+00	2026-02-14 15:14:15.553352+00	2026-02-14 15:14:15.553352+00
fe67116b-0ad9-4491-9670-f40d1939db1e	contributor	1	0	0	0	0	0.000	510	500	0	0	2026-02-15 18:10:30.178+00	2026-02-15 18:10:01.54922+00	2026-02-15 18:10:01.54922+00
577de5d6-c06e-4583-9631-9817db23b84d	contributor	1	0	0	0	0	0	0	0	0	0	2026-02-15 23:20:59.707+00	2026-02-15 23:20:58.350214+00	2026-02-15 23:20:58.350214+00
955ff6c1-f3db-4087-8e68-cb67ffc41862	contributor	1	0	0	0	0	0.000	544	1586	0	0	2026-02-15 23:48:43.741+00	2026-02-15 23:06:07.830602+00	2026-02-15 23:06:07.830602+00
\.


--
-- Data for Name: qa_tickets; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_tickets (id, ticket_number, reporter_id, category, severity, status, title, description, steps_to_reproduce, expected_behavior, actual_behavior, page_url, user_agent, browser_info, screenshots, duplicate_of, is_verified, verified_by, verified_at, verification_count, assigned_to, resolved_by, resolved_at, resolution_notes, reward_xp, reward_credits, bounty_id, upvotes, priority_score, tags, metadata, created_at, updated_at) FROM stdin;
1f42bae8-d081-4c46-acc9-f04c7585fdc2	QA-000001	a0000000-0000-0000-0000-000000000001	backend	major	new	фывфывафы	афывафывафывафывафывафывафыва	\N	\N	\N	http://localhost/bug-reports	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36	{}	["http://localhost/storage/v1/object/public/avatars/bug-reports/a0000000-0000-0000-0000-000000000001/1771082055431.jpg"]	\N	f	\N	\N	0	\N	\N	\N	\N	0	0	\N	0	0	{}	{}	2026-02-14 15:14:15.515827+00	2026-02-14 15:14:15.515827+00
0bf07d89-dcf1-468e-a626-7cd02e74d513	QA-000002	a0000000-0000-0000-0000-000000000001	frontend	blocker	new	ывапывапывапывап	ывапывапывапывапывапывапывап	\N	\N	\N	http://localhost/bug-reports	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36	{}	["http://localhost/storage/v1/object/public/avatars/bug-reports/a0000000-0000-0000-0000-000000000001/1771082102559.jfif"]	\N	f	\N	\N	0	\N	\N	\N	\N	0	0	\N	0	0	{}	{}	2026-02-14 15:15:02.679854+00	2026-02-14 15:15:02.679854+00
fbb07705-9e53-4f05-86f7-35e34a407488	QA-000003	a0000000-0000-0000-0000-000000000001	backend	major	new	ывапывапывапывапывапвыа	ырывпрывапрыварпыварпывапывапывапывапывапывапв	\N	\N	\N	http://localhost/admin	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36	{}	["http://localhost/storage/v1/object/public/avatars/bug-reports/a0000000-0000-0000-0000-000000000001/1771085332572.jpg"]	\N	f	\N	\N	0	\N	\N	\N	\N	0	0	\N	0	0	{}	{}	2026-02-14 16:08:52.697692+00	2026-02-14 16:08:52.697692+00
8db18bd5-f4d9-4b56-8167-04c6f460515a	QA-000005	955ff6c1-f3db-4087-8e68-cb67ffc41862	ui	minor	confirmed	фывафыва	фывафывафывфывафывафывафываф	\N	\N	\N	https://aimuza.ru/?tab=music	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 YaBrowser/25.12.0.0 Safari/537.36	{}	["https://aimuza.ru/storage/v1/object/public/avatars/bug-reports/955ff6c1-f3db-4087-8e68-cb67ffc41862/1771196769448.jfif"]	\N	f	\N	\N	0	\N	\N	\N	\N	100	500	\N	0	0	{}	{}	2026-02-15 23:06:07.80478+00	2026-02-15 23:07:17.628938+00
f13f18f8-5a35-4291-b479-d68f4e53caa2	QA-000004	fe67116b-0ad9-4491-9670-f40d1939db1e	other	minor	confirmed	кенкенун	Не прошла верификацию	\N	\N	\N	https://aimuza.ru/bug-reports	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 YaBrowser/25.12.0.0 Safari/537.36	{}	[]	\N	f	\N	\N	0	\N	\N	\N	\N	10	500	\N	0	0	{}	{}	2026-02-15 18:10:01.526856+00	2026-02-15 23:08:49.905797+00
36818bd3-9aaa-40c7-bbed-b521693c5669	QA-000006	577de5d6-c06e-4583-9631-9817db23b84d	other	blocker	new	МОЙ мОЗГ	НЕ МОГУ НАЙТИ КНОПКУ	\N	\N	\N	https://aimuza.ru/?tab=settings	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 YaBrowser/25.12.0.0 Safari/537.36	{}	[]	\N	f	\N	\N	0	\N	\N	\N	\N	0	0	\N	0	0	{}	{}	2026-02-15 23:20:58.307881+00	2026-02-15 23:20:58.307881+00
a37355c0-764c-4204-a733-ed5eacfe7ba5	QA-000007	955ff6c1-f3db-4087-8e68-cb67ffc41862	frontend	minor	confirmed	фывафыва	фывафываываывфффывафывав	\N	\N	\N	https://aimuza.ru/profile/%D0%A1%D1%82%D1%80%D0%B0%D0%B4%D0%B0%D0%BB%D0%B5%D1%86-955ff6	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 YaBrowser/25.12.0.0 Safari/537.36	{}	[]	\N	f	\N	\N	0	\N	\N	\N	\N	100	500	\N	0	0	{}	{}	2026-02-15 23:33:46.027561+00	2026-02-15 23:34:39.371632+00
86275204-c706-45be-bba6-2425a4caca93	QA-000008	955ff6c1-f3db-4087-8e68-cb67ffc41862	frontend	major	confirmed	фывфывва	фывафываыфввафывафываыв	\N	\N	\N	https://aimuza.ru/profile/%D0%A1%D1%82%D1%80%D0%B0%D0%B4%D0%B0%D0%BB%D0%B5%D1%86-955ff6	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 YaBrowser/25.12.0.0 Safari/537.36	{}	["https://aimuza.ru/storage/v1/object/public/avatars/bug-reports/955ff6c1-f3db-4087-8e68-cb67ffc41862/1771199323688.jfif"]	\N	f	\N	\N	0	\N	\N	\N	\N	94	86	\N	0	0	{}	{}	2026-02-15 23:48:41.839891+00	2026-02-15 23:49:59.937962+00
\.


--
-- Data for Name: qa_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qa_votes (id, ticket_id, user_id, vote_type, voter_weight, comment, created_at) FROM stdin;
\.


--
-- Data for Name: radio_ad_placements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_ad_placements (id, advertiser_name, ad_type, audio_url, promo_text, price_paid, impressions, clicks, starts_at, ends_at, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: radio_bids; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_bids (id, slot_id, user_id, track_id, amount, status, created_at) FROM stdin;
\.


--
-- Data for Name: radio_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_config (key, value, label, description, updated_at) FROM stdin;
auction	{"enabled": true, "min_bid_rub": 10, "bid_step_rub": 5, "max_active_slots": 3, "author_share_percent": 80, "slot_duration_minutes": 60, "auto_extend_if_no_bids": false, "cooldown_after_slot_hours": 4, "platform_commission_percent": 20}	Аукцион слотов	Механика «Платных слотов» — аукцион за право быть следующим в эфире	2026-02-14 15:33:03.672945+00
listen_to_earn	{"enabled": true, "xp_per_vote": 3, "xp_daily_cap": 100, "afk_penalty_xp": -10, "xp_per_reaction": 1, "afk_max_failures": 3, "min_listen_percent": 60, "xp_per_full_listen": 2, "xp_diminishing_rate": 0.5, "xp_diminishing_after": 20, "afk_check_timeout_sec": 15, "afk_check_interval_sec": 120, "xp_per_prediction_wrong": 1, "xp_per_prediction_correct": 10, "bot_detection_same_ip_limit": 5, "bot_detection_speed_threshold_ms": 200}	Listen-to-Earn	Геймификация прослушивания: XP за слушание, реакции, голосования, прогнозы. Anti-AFK проверки.	2026-02-14 15:33:03.672945+00
predictions	{"enabled": true, "bet_max_rub": 100, "bet_min_rub": 5, "burn_percent": 5, "hit_window_hours": 24, "refund_on_cancel": true, "payout_multiplier": 1.8, "hit_threshold_likes": 10, "platform_commission_percent": 10}	Прогнозы	Система ставок: слушатели ставят на то, станет ли трек хитом. Комиссия + burn валюты.	2026-02-14 15:33:03.672945+00
advertising	{"enabled": false, "ad_free_for_tiers": ["producer", "maestro"], "skip_ad_price_rub": 5, "sponsored_hour_enabled": false, "author_ad_share_percent": 60, "sponsored_hour_price_rub": 5000, "audio_ad_max_duration_sec": 15, "platform_ad_share_percent": 40, "audio_ad_slot_every_n_tracks": 5}	Реклама	AI-реклама: аудио-вставки, спонсорский час, распределение дохода между платформой и авторами	2026-02-14 15:33:03.672945+00
server	{"cdn_for_audio": true, "redis_recommended": true, "audio_bitrate_kbps": 128, "recommended_ram_gb": 4, "recommended_ssd_gb": 50, "separate_container": true, "buffer_ahead_tracks": 3, "recommended_cpu_cores": 2, "websocket_heartbeat_sec": 30, "max_concurrent_listeners": 500, "queue_worker_interval_ms": 5000}	Сервер	Рекомендуемые серверные параметры для модуля радио	2026-02-14 15:33:03.672945+00
smart_stream	{"W_xp": 0.25, "W_stake": 0.20, "W_quality": 0.35, "queue_size": 50, "W_discovery": 0.05, "W_freshness": 0.15, "min_duration_sec": 30, "min_quality_score": 2.0, "recalc_interval_sec": 300, "discovery_boost_days": 14, "max_author_share_percent": 15, "discovery_boost_multiplier": 2.5, "max_plays_per_track_per_hour": 3}	Smart Stream	Веса алгоритма ротации: W1=quality, W2=xp, W3=stake, W4=freshness, W5=discovery. Discovery-лифт для новичков.	2026-02-14 15:33:03.672945+00
\.


--
-- Data for Name: radio_listens; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_listens (id, user_id, track_id, session_id, listen_duration_sec, track_duration_sec, listen_percent, xp_earned, reaction, is_afk_verified, afk_response_ms, ip_hash, created_at) FROM stdin;
d8c01da9-644e-433f-a560-fc58d85af969	fe67116b-0ad9-4491-9670-f40d1939db1e	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	18cab9e0-6127-4b77-8a12-48a253e1d511	50	113	44.24778761061946902700	0	\N	f	\N	18cab9e0	2026-02-15 17:28:20.725626+00
a17c85e0-c72d-44bd-8ef8-0803363c27b1	fe67116b-0ad9-4491-9670-f40d1939db1e	2200c86c-1f8e-4eb6-badc-1c501e3fd526	02d0e251-8a8a-4ffb-88fe-bd30c907b789	16	240	6.66666666666666666700	1	like	f	\N	02d0e251	2026-02-15 19:41:03.353074+00
43eafea1-961b-42f3-ad24-b76935fb36d1	fe67116b-0ad9-4491-9670-f40d1939db1e	92009d5e-9657-4d91-a402-e29cfc1a4bc9	02d0e251-8a8a-4ffb-88fe-bd30c907b789	8	239	3.34728033472803347300	0	\N	f	\N	02d0e251	2026-02-15 19:41:23.307923+00
\.


--
-- Data for Name: radio_predictions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_predictions (id, user_id, track_id, bet_amount, predicted_hit, actual_result, payout, status, expires_at, created_at) FROM stdin;
\.


--
-- Data for Name: radio_queue; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_queue (id, track_id, user_id, source, "position", chance_score, quality_component, xp_component, stake_component, freshness_component, discovery_component, played_at, is_played, genre_id, created_at) FROM stdin;
fb163809-945b-4946-abf5-954e7b2a1bba	c43442e2-28f8-4243-b4e0-d65d69d73b6f	a0000000-0000-0000-0000-000000000001	algorithm	0	63.698136410823246	50	100	0	91.12349757870416	0	\N	f	\N	2026-02-17 15:40:10.080587+00
fd29863f-1d54-41ce-898c-6ac93a393893	b6baa477-fa9a-4560-86d5-534d33843e69	a0000000-0000-0000-0000-000000000001	algorithm	1	62.66655606834026	50	100	0	91.12857974715833	0	\N	f	\N	2026-02-17 15:40:10.082133+00
d07b464f-f9fc-4404-a350-d702de3ed1b2	6ea24ec5-3965-42f9-aa7f-c20c1799fac0	a0000000-0000-0000-0000-000000000001	algorithm	2	65.23885141020433	50.5	100	0	93.87924201569479	0	\N	f	\N	2026-02-17 15:40:10.082949+00
dac8f378-8714-4d24-a04d-b347165d5d9c	d65b1d46-fb85-4e12-894f-e8503ff36705	a0000000-0000-0000-0000-000000000001	algorithm	3	57.60993104449744	50	100	0	91.12349757870416	0	\N	f	\N	2026-02-17 15:40:10.083711+00
2cf1446e-b5ff-4db4-9e2f-6a2c5f9a40fc	f2fd97b5-c96e-40c1-9ab6-ec1453869d8f	a0000000-0000-0000-0000-000000000001	algorithm	4	64.91682955597827	50	100	0	93.87924201569479	0	\N	f	\N	2026-02-17 15:40:10.084362+00
b31e7121-aef1-470a-b4bf-55bc4f28cf38	a77ad808-fb29-4632-ae70-10e5fee26a42	a0000000-0000-0000-0000-000000000001	algorithm	5	60.55178326226232	50	100	0	94.02011938430626	0	\N	f	\N	2026-02-17 15:40:10.085144+00
55c50cfa-a8d3-4c89-a972-db846df57d43	75ffa1b3-2874-4fe1-880e-fd2ec01b9c93	a0000000-0000-0000-0000-000000000001	algorithm	6	62.0742021437809	50	100	0	93.14413087329375	0	\N	f	\N	2026-02-17 15:40:10.085811+00
6298728c-5f6e-4a02-9a95-16a2831554d2	ee7e9211-f25e-4b5a-b5e5-5a633d578a22	a0000000-0000-0000-0000-000000000001	algorithm	7	62.03807644398229	50	100	0	91.02425290011875	0	\N	f	\N	2026-02-17 15:40:10.086395+00
01860739-6995-4df1-b75b-810afafd8135	697b5df5-1310-4e6d-80a0-934641535b9d	a0000000-0000-0000-0000-000000000001	algorithm	8	59.95079128613724	50	100	0	91.06353499656355	0	\N	f	\N	2026-02-17 15:40:10.086993+00
9efce652-0030-4dfb-b7ec-75d1fb7d8cf5	92009d5e-9657-4d91-a402-e29cfc1a4bc9	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	9	53.67288474959776	50	0	0	93.88079757262396	250	\N	f	\N	2026-02-17 15:40:10.087475+00
544ef2d8-6531-4686-ac11-04b85e638fb5	666e95a3-d230-42d0-87ce-3081a0cc299d	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	10	46.57710010525193	50.5	0	0	93.88098489664792	250	\N	f	\N	2026-02-17 15:40:10.09427+00
1c4d48d6-36f7-4c05-bc39-03648e877b93	376aa628-eafd-48a3-9d11-f46e81c99eb3	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	11	50.40022371135085	50.5	0	0	91.06660819975937	250	\N	f	\N	2026-02-17 15:40:10.095138+00
87d0297c-9418-4356-a1da-4a4b774c42da	2200c86c-1f8e-4eb6-badc-1c501e3fd526	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	12	46.252713584810664	50.5	0	0	91.11004671729688	250	\N	f	\N	2026-02-17 15:40:10.095717+00
fc5f5e67-abe8-4f22-9626-b8104f7373e7	a90a39d1-7041-40c5-9ec1-c3984a962df3	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	13	51.11476410983363	50	0	0	94.18418499705625	250	\N	f	\N	2026-02-17 15:40:10.096235+00
71677f21-c61a-4f20-b393-41927da79c3b	9ddaaf22-632a-4a3f-b717-2a0727f1cd36	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	14	53.72868776767926	50	0	0	94.5965292833	250	\N	f	\N	2026-02-17 15:40:10.09688+00
26e433f5-37b4-4699-a321-66f482e6b906	62ba5a2a-20e6-4cff-bd09-1e5da9459cab	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	15	52.89698226181655	50	0	0	94.18418499705625	250	\N	f	\N	2026-02-17 15:40:10.097406+00
7251db92-81af-465f-8c4e-0e4b0ab0abc8	4e620d16-6236-42d2-84b1-243f6b93c095	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	16	47.77059164875892	50	0	0	91.11004671729688	250	\N	f	\N	2026-02-17 15:40:10.097858+00
4df5b69a-d9a0-47f8-92a1-6f87acb6e6c8	afbd5a33-9e4d-4770-bbf2-cd8d68b77806	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	17	45.39606890064614	50	0	0	94.6089919241948	250	\N	f	\N	2026-02-17 15:40:10.0983+00
f0eb191b-5c54-4e04-9d8d-57d22b47606c	a394a39c-dedd-45a0-911e-d1830d5ee047	955ff6c1-f3db-4087-8e68-cb67ffc41862	algorithm	18	50.68153241916193	50	0	0	93.88079757262396	250	\N	f	\N	2026-02-17 15:40:10.098792+00
\.


--
-- Data for Name: radio_slots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.radio_slots (id, slot_number, starts_at, ends_at, status, winner_user_id, winner_track_id, winning_bid, total_bids, created_at) FROM stdin;
\.


--
-- Data for Name: referral_codes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.referral_codes (id, user_id, code, uses_count, max_uses, expires_at, created_at) FROM stdin;
\.


--
-- Data for Name: referral_rewards; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.referral_rewards (id, referral_id, user_id, type, amount, status, created_at) FROM stdin;
\.


--
-- Data for Name: referral_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.referral_settings (id, key, value, created_at) FROM stdin;
\.


--
-- Data for Name: referral_stats; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.referral_stats (id, user_id, total_referrals, active_referrals, total_earned, updated_at) FROM stdin;
\.


--
-- Data for Name: referrals; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.referrals (id, referrer_id, referred_id, bonus_amount, status, created_at) FROM stdin;
\.


--
-- Data for Name: reputation_events; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.reputation_events (id, user_id, event_type, xp_delta, reputation_delta, category, source_type, source_id, metadata, created_at) FROM stdin;
542f2cfe-315d-4d0e-9f21-dd9cb81e0778	fe67116b-0ad9-4491-9670-f40d1939db1e	qa_report_resolved	15	5	general	qa_ticket	f13f18f8-5a35-4291-b479-d68f4e53caa2	{"bounty_id": null, "xp_custom": 500}	2026-02-15 18:11:26.615553+00
46de78d3-629d-495c-b9bd-04153108cc19	fe67116b-0ad9-4491-9670-f40d1939db1e	radio_listen	1	0	music	track	2200c86c-1f8e-4eb6-badc-1c501e3fd526	{"listen_pct": 6.66666666666666666700}	2026-02-15 19:41:03.353074+00
f685a054-897a-403d-ac16-390f65f1f26e	955ff6c1-f3db-4087-8e68-cb67ffc41862	qa_report_resolved	15	5	general	qa_ticket	8db18bd5-f4d9-4b56-8167-04c6f460515a	{"bounty_id": null, "xp_custom": 100}	2026-02-15 23:07:17.628938+00
31df700b-3540-43f7-8cf9-2aef85805616	fe67116b-0ad9-4491-9670-f40d1939db1e	qa_report_resolved	15	5	general	qa_ticket	f13f18f8-5a35-4291-b479-d68f4e53caa2	{"bounty_id": null, "xp_custom": 10}	2026-02-15 23:08:49.905797+00
00d10c75-a0e2-4796-ba31-8e6d6c1fa0a2	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin_bonus	150	10	general	\N	\N	{"reason": "ыфавфыавфыавф", "admin_id": "a0000000-0000-0000-0000-000000000001"}	2026-02-15 23:19:01.812518+00
4fdeed2d-dce8-4e1e-89e1-4b43dfaeb656	955ff6c1-f3db-4087-8e68-cb67ffc41862	qa_report_resolved	100	10	general	qa_ticket	a37355c0-764c-4204-a733-ed5eacfe7ba5	{"bounty_id": null, "xp_custom": 100}	2026-02-15 23:34:39.371632+00
44ebf436-ed13-452e-8d2f-0bd5b728d2be	955ff6c1-f3db-4087-8e68-cb67ffc41862	qa_report_resolved	250	10	general	qa_ticket	86275204-c706-45be-bba6-2425a4caca93	{"bounty_id": null, "xp_custom": 250}	2026-02-15 23:49:15.178929+00
9711b886-2596-4c68-bbb6-0a203e6143fd	955ff6c1-f3db-4087-8e68-cb67ffc41862	qa_report_resolved	94	10	general	qa_ticket	86275204-c706-45be-bba6-2425a4caca93	{"bounty_id": null, "xp_custom": 94}	2026-02-15 23:49:59.937962+00
5897692f-4214-4402-917d-23716d2b5dbd	955ff6c1-f3db-4087-8e68-cb67ffc41862	forum_xp	1	0	forum	trigger	\N	{"via": "fn_add_xp"}	2026-02-16 00:59:48.36156+00
0a3b3fc3-1fde-4386-a398-a69ccd4e9071	955ff6c1-f3db-4087-8e68-cb67ffc41862	forum_xp	-1	0	forum	trigger	\N	{"via": "fn_add_xp"}	2026-02-16 00:59:48.372136+00
948f4196-c10c-4d39-9c8c-5d2932fe51c9	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin_bonus	12	6	general	\N	\N	{"reason": "Ручное начисление администратором", "admin_id": "a0000000-0000-0000-0000-000000000001"}	2026-02-16 01:18:50.091117+00
646dfb8a-1f6e-4e75-82fd-b6f1d8d59bb8	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin_deduct	-521	-10	general	admin	\N	{"reason": "Списание администратором"}	2026-02-16 01:30:45.66673+00
108b7ecc-fb04-44f9-8c7c-abad3ce6dd16	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin_bonus	10000	10	general	\N	\N	{"reason": "Ручное начисление администратором", "admin_id": "a0000000-0000-0000-0000-000000000001"}	2026-02-16 01:32:33.058835+00
c25354b9-5a36-4736-abbd-bb3809fc5736	955ff6c1-f3db-4087-8e68-cb67ffc41862	achievement_unlocked	500	0	general	achievement	ee1c37d0-eeb4-4159-a738-99719e3ac63c	{"achievement_key": "legend", "achievement_name": "Легенда"}	2026-02-16 01:32:33.058835+00
0c6016d3-1f22-4428-87ef-f8d3a70294a4	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin_deduct	-10600	-10	general	admin	\N	{"reason": "Списание администратором"}	2026-02-16 01:33:11.06807+00
5734e9c8-62a4-47a8-a504-29b15c95f27e	a0000000-0000-0000-0000-000000000001	admin_bonus	50000	10	general	\N	\N	{"reason": "Ручное начисление администратором", "admin_id": "a0000000-0000-0000-0000-000000000001"}	2026-02-16 01:33:44.8428+00
def60c8d-f291-4577-9afd-6690643de10e	a0000000-0000-0000-0000-000000000001	achievement_unlocked	500	0	general	achievement	ee1c37d0-eeb4-4159-a738-99719e3ac63c	{"achievement_key": "legend", "achievement_name": "Легенда"}	2026-02-16 01:33:44.8428+00
\.


--
-- Data for Name: reputation_tiers; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.reputation_tiers (id, key, name_ru, name_en, level, min_xp, icon, color, gradient, vote_weight, perks, created_at, marketplace_commission, attribution_multiplier, bonus_generations, feed_boost, can_sell_premium, can_create_voice_print) FROM stdin;
98d26f84-45b0-4d3f-9261-f484348dbaed	newcomer	Новичок	Newcomer	0	0	🎵	#6B7280	from-gray-500/15 to-gray-500/5	1.00	{"daily_generations": 5}	2026-02-14 11:03:59.84541+00	0.150	0.00	0	1.00	f	f
fbadbe08-47d5-4387-9a3b-03cecf122b8b	beat_maker	Битмейкер	Beat Maker	1	50	🎹	#3B82F6	from-blue-500/15 to-blue-500/5	1.20	{"can_vote": true, "daily_generations": 10}	2026-02-14 11:03:59.84541+00	0.120	1.00	5	1.20	f	f
1d8a9f05-48c3-4cfb-9437-be1c7ff001b4	sound_designer	Саунд-дизайнер	Sound Designer	2	200	🎛️	#10B981	from-emerald-500/15 to-emerald-500/5	1.50	{"can_vote": true, "can_curate": true, "daily_generations": 15}	2026-02-14 11:03:59.84541+00	0.100	1.00	10	1.50	t	f
c178bee2-b2a4-4e4f-83be-1bb1a6f78240	producer	Продюсер	Producer	3	500	🎧	#F59E0B	from-amber-500/15 to-amber-500/5	2.00	{"can_vote": true, "can_curate": true, "vote_highlight": true, "daily_generations": 25}	2026-02-14 11:03:59.84541+00	0.070	1.50	20	2.00	t	t
3af4b4ac-cf29-414d-8c77-f28e030b318c	maestro	ИИ-Маэстро	AI Maestro	4	1500	👑	#A855F7	from-purple-500/15 to-purple-500/5	3.00	{"can_vote": true, "can_curate": true, "vote_highlight": true, "featured_profile": true, "daily_generations": 50}	2026-02-14 11:03:59.84541+00	0.050	2.00	30	3.00	t	t
\.


--
-- Data for Name: role_change_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.role_change_logs (id, user_id, changed_by, action, reason, metadata, old_role, new_role, created_at) FROM stdin;
2b7f108d-1243-46fc-a137-13b2f19d5061	\N	a0000000-0000-0000-0000-000000000001	user_deleted	\N	{"username": "shvedov.roman@mail.ru"}	\N	\N	2026-02-13 13:11:14.709385+00
2c2adb7a-2b9c-4286-9833-d9b3c8861969	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"new_balance": 520, "old_balance": 80}	\N	\N	2026-02-14 21:52:40.819253+00
6baeda98-deae-4b66-ac54-ac1e0ddfcf25	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 80, "new_balance": 600, "old_balance": 520}	\N	\N	2026-02-14 22:43:23.933235+00
8d269fe2-3cbd-47ff-827f-fe951e4f0b23	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	moderation_approved	\N	{"track_id": "376aa628-eafd-48a3-9d11-f46e81c99eb3", "track_title": "Тест редактора"}	\N	\N	2026-02-14 23:17:15.864067+00
ed720c12-ebed-423f-ba75-496034d37779	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	moderation_sent_to_voting	\N	{"track_id": "877a4bd9-5c2a-44a8-8082-699113dfd91e", "track_title": "Черновик 1", "voting_type": "public"}	\N	\N	2026-02-14 23:17:49.977658+00
2ffa64ac-0352-4d6f-8857-b8706a361cbc	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	moderation_sent_to_voting	\N	{"track_id": "877a4bd9-5c2a-44a8-8082-699113dfd91e", "track_title": "Черновик 1", "voting_type": "public"}	\N	\N	2026-02-14 23:37:48.799198+00
2ee0acb9-19a7-4757-9bdb-0bcf14c83b04	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	moderation_sent_to_voting	\N	{"track_id": "877a4bd9-5c2a-44a8-8082-699113dfd91e", "track_title": "Черновик 1", "voting_type": "public"}	\N	\N	2026-02-15 00:05:56.439577+00
a115c813-adf7-401b-bf87-7e02a6c4fc7d	a0000000-0000-0000-0000-000000000001	a0000000-0000-0000-0000-000000000001	moderation_sent_to_voting	\N	{"track_id": "b6baa477-fa9a-4560-86d5-534d33843e69", "track_title": "в стиле Inward Universe (v2)", "voting_type": "public"}	\N	\N	2026-02-15 01:32:25.324851+00
ddc65d79-ec08-4723-8326-979e2a11a2aa	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	invited	\N	{"invitation_id": "00385b8e-1f8b-4d53-b33a-9a3bc65f6150"}	\N	admin	2026-02-15 15:56:24.613046+00
18f45f79-c8d2-4517-b750-7e53581b5b4d	fe67116b-0ad9-4491-9670-f40d1939db1e	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 5000, "new_balance": 5100, "old_balance": 100}	\N	\N	2026-02-15 17:06:23.376972+00
fe2a363a-0d7f-4fa5-b240-205d95b44ca4	fe67116b-0ad9-4491-9670-f40d1939db1e	a0000000-0000-0000-0000-000000000001	invited	\N	{"invitation_id": "678ffa2c-2ca8-4b4b-b8ae-722df3df3d23"}	\N	admin	2026-02-15 17:09:08.561491+00
9f0a11e5-e15a-48b8-bf60-cf3de8e4f583	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	accepted	\N	{"invitation_id": "00385b8e-1f8b-4d53-b33a-9a3bc65f6150"}	\N	admin	2026-02-15 17:35:43.922167+00
cd0c5172-93b4-4ac4-bc46-0a6d8374e410	fe67116b-0ad9-4491-9670-f40d1939db1e	a0000000-0000-0000-0000-000000000001	accepted	\N	{"invitation_id": "678ffa2c-2ca8-4b4b-b8ae-722df3df3d23"}	\N	admin	2026-02-15 18:01:04.090374+00
07b8c9e7-5ba3-4943-8cd4-e01e6113bc74	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	revoked	\N	\N	admin	\N	2026-02-15 18:05:55.097538+00
e44e73a3-31d6-4da2-b2e7-0cab1fb7af7f	fe67116b-0ad9-4491-9670-f40d1939db1e	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 5000, "new_balance": 9566, "old_balance": 4566}	\N	\N	2026-02-15 20:15:37.83575+00
9bb5f240-87d3-416c-a117-c38a046de953	577de5d6-c06e-4583-9631-9817db23b84d	a0000000-0000-0000-0000-000000000001	invited	\N	{"invitation_id": "d362d0bf-679b-4638-b54c-e164f7ccd8cd"}	\N	admin	2026-02-15 21:58:21.857578+00
3219dcb4-4b57-458d-9669-56e654f79caa	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 1000, "new_balance": 1161, "old_balance": 161}	\N	\N	2026-02-15 21:58:49.293656+00
57e47ab3-3fff-46ea-b511-20466a3c344d	577de5d6-c06e-4583-9631-9817db23b84d	a0000000-0000-0000-0000-000000000001	accepted	\N	{"invitation_id": "d362d0bf-679b-4638-b54c-e164f7ccd8cd"}	\N	admin	2026-02-15 22:02:16.005847+00
ac0fdbb2-4e71-4ea7-9608-c9e47d84dbca	577de5d6-c06e-4583-9631-9817db23b84d	577de5d6-c06e-4583-9631-9817db23b84d	balance_changed	\N	{"delta": 1000, "new_balance": 1100, "old_balance": 100}	\N	\N	2026-02-15 22:10:20.926868+00
b3cee1b3-e42f-4dc1-a9c8-098d6679c995	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 5000, "new_balance": 5204, "old_balance": 204}	\N	\N	2026-02-15 22:37:08.997962+00
8af8b53b-3991-4b11-a12c-db4d5b966ff5	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 222, "new_balance": 6490, "old_balance": 6268}	\N	\N	2026-02-16 00:49:27.57583+00
5754de33-3714-4eb4-99c7-506c5e06d192	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	balance_changed	\N	{"delta": 122, "new_balance": 6612, "old_balance": 6490}	\N	\N	2026-02-16 00:50:18.682496+00
7c1044c6-51a6-4c54-9f97-48141ba5d48f	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	invited	\N	{"invitation_id": "bd216ba9-b338-4705-8936-208748f69717"}	\N	admin	2026-02-16 10:39:18.987494+00
166d0b90-cbec-4b62-a103-17a3f719965e	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	accepted	\N	{"invitation_id": "bd216ba9-b338-4705-8936-208748f69717"}	\N	admin	2026-02-16 10:39:35.218036+00
6331391e-d0a5-4f01-9811-d5281a8ed3a1	955ff6c1-f3db-4087-8e68-cb67ffc41862	a0000000-0000-0000-0000-000000000001	revoked	\N	\N	admin	\N	2026-02-16 10:40:28.443533+00
\.


--
-- Data for Name: role_invitation_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.role_invitation_permissions (id, invitation_id, category_id, created_at) FROM stdin;
\.


--
-- Data for Name: role_invitations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.role_invitations (id, user_id, role, status, invited_by, expires_at, created_at, message, responded_at) FROM stdin;
00385b8e-1f8b-4d53-b33a-9a3bc65f6150	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin	accepted	a0000000-0000-0000-0000-000000000001	2026-02-22 15:56:24.597809+00	2026-02-15 15:56:24.597809+00	\N	2026-02-15 17:35:43.922167+00
678ffa2c-2ca8-4b4b-b8ae-722df3df3d23	fe67116b-0ad9-4491-9670-f40d1939db1e	admin	accepted	a0000000-0000-0000-0000-000000000001	2026-02-22 17:09:08.545322+00	2026-02-15 17:09:08.545322+00	\N	2026-02-15 18:01:04.090374+00
d362d0bf-679b-4638-b54c-e164f7ccd8cd	577de5d6-c06e-4583-9631-9817db23b84d	admin	accepted	a0000000-0000-0000-0000-000000000001	2026-02-22 21:58:21.842475+00	2026-02-15 21:58:21.842475+00	\N	2026-02-15 22:02:16.005847+00
bd216ba9-b338-4705-8936-208748f69717	955ff6c1-f3db-4087-8e68-cb67ffc41862	admin	accepted	a0000000-0000-0000-0000-000000000001	2026-02-23 10:39:18.964914+00	2026-02-16 10:39:18.964914+00	\N	2026-02-16 10:39:35.218036+00
\.


--
-- Data for Name: security_audit_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.security_audit_log (id, user_id, action, ip_address, user_agent, metadata, created_at) FROM stdin;
\.


--
-- Data for Name: seller_earnings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.seller_earnings (id, user_id, source_type, source_id, amount, platform_fee, net_amount, status, created_at) FROM stdin;
\.


--
-- Data for Name: settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.settings (id, key, value, updated_at, created_at, description) FROM stdin;
8996d5b8-b09e-4292-8658-4449ab6f0b3f	maintenance_message		2026-02-13 12:07:53.823488+00	2026-02-14 21:32:34.165728+00	\N
07a1256a-e139-4206-8dfe-6fe4d4644d30	forum_animations_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл анимации
d6550b53-a7c4-411a-8fbd-447efe6e6018	forum_polls_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл опросы
49050316-f039-4ed6-bf69-41d87dfb1500	forum_search_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл поиск
757f108d-cdcd-4a6d-b6aa-3751e457e81e	deposit_price_blockchain	300	2026-01-21 19:05:44.386236+00	2026-01-21 17:31:18.10347+00	\N
112e3529-232c-45cd-bc92-b2cde5884cce	boost_style_cost_rub	0	2026-01-29 10:08:15.575067+00	2026-01-29 09:50:05.208908+00	\N
23d27959-358d-4e70-b872-5b0e40573204	price_per_image	10	2026-01-17 14:06:10.600622+00	2026-01-17 14:06:10.600622+00	Цена за генерацию изображения (₽)
e26d3361-0913-4db7-9ea3-c681af8c0215	price_per_video	25	2026-01-17 14:06:10.600622+00	2026-01-17 14:06:10.600622+00	Цена за генерацию видео (₽)
c7a6bfdc-cca7-4463-ab1d-43e94b6058f1	vocal_separation_price	15	2026-01-17 14:24:11.025085+00	2026-01-17 14:24:11.025085+00	Стоимость разделения вокала в ₽
a24b3f61-9290-40e2-9b90-abc629313ac0	stem_separation_price	20	2026-01-17 14:24:11.025085+00	2026-01-17 14:24:11.025085+00	Стоимость разделения дорожек в ₽
9e8272dd-c6d3-4589-ac29-9bfcdd534608	ringtone_cost_rub	0	2026-01-29 10:08:28.178573+00	2026-01-17 18:12:54.073356+00	Себестоимость рингтона в рублях
51081e45-6538-4091-be4e-8b157aa98f97	generation_price	26	2026-01-29 10:08:58.780511+00	2026-01-17 13:15:06.165595+00	Стоимость генерации трека в ₽
4d56f49f-42e3-4889-86be-245117e1f7d0	queue_max_concurrent_global	3	2026-01-29 16:16:56.832843+00	2026-01-29 16:16:56.832843+00	Maximum simultaneous generations globally
827a6d9b-afc1-414c-9463-b8505b00b0fe	queue_max_per_user	1	2026-01-29 16:16:56.832843+00	2026-01-29 16:16:56.832843+00	Maximum active generations per user
e14acfa8-f044-4917-a261-b67a0596bcf3	backup_pin_hash	16701a2e2b05e54501e66a901a44a250e549d5e87cc9bddffeb54880b4d584aa	2026-02-01 17:32:36.222975+00	2026-02-01 17:29:34.686766+00	SHA-256 хеш пин-кода для экспорта БД (только super_admin)
d4083ba4-b33d-4336-8c14-14d445e7d5db	suno_credits_per_generation	12	2026-01-17 18:17:38.566613+00	2026-01-17 18:12:54.073356+00	Кредиты Suno расходуемые на генерацию
9f2845ff-a3a4-49d1-8657-a4c26348d5e1	suno_cost_per_credit	0.45	2026-01-17 18:20:32.462758+00	2026-01-17 18:12:54.073356+00	Себестоимость одного кредита Suno в рублях
cd06d260-da6a-4e7b-917b-54f0602ade04	tax_percentage	13	2026-01-17 18:23:56.640874+00	2026-01-17 18:12:54.073356+00	Процент налога (УСН и т.п.)
8a75720a-b580-4f72-a1ef-d0b8fe7f613b	super_admin_id	d9feb0b2-28c8-4c8d-b2fe-30ece80f5520	2026-01-17 18:56:42.768284+00	2026-01-17 18:56:17.102062+00	ID главного администратора (защищённый)
7043377c-11b8-4807-b7cb-f815378acd9d	hd_cover_cost_rub	8	2026-01-20 03:13:30.88741+00	2026-01-17 18:12:54.073356+00	Себестоимость HD обложки в рублях
158cc944-8490-4620-a132-2faeea0e5991	short_video_cost_rub	8	2026-01-20 03:13:46.872764+00	2026-01-17 18:12:54.073356+00	Себестоимость короткого видео в рублях
a9081893-8dec-4673-a005-7c4fcddf8e1f	forum_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл форум
017b0fc1-6082-4355-8c4a-625416d95f8a	add_vocal_price	15	2026-01-20 21:31:59.686494+00	2026-01-20 21:31:59.686494+00	Стоимость добавления вокала к инструменталу
82f54d22-1dbf-4b1d-b341-4dab1ccb193f	upload_cover_price	15	2026-01-20 21:31:59.686494+00	2026-01-20 21:31:59.686494+00	Стоимость создания кавер-версии
4c1a9710-58cd-499a-b8b9-2253df320f44	trial_lyrics_editor_enabled	true	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Включить пробный период для редактора текста
34cd7400-c059-4ef6-9e8f-d34931359db9	trial_lyrics_editor_uses	3	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Количество бесплатных попыток редактора текста
6938a0ad-c114-477e-9c9b-4c56b5a534fa	trial_prompts_marketplace_enabled	true	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Включить пробный период для маркетплейса промптов
439ff92c-a463-4c35-8b17-f42fe4f0ca40	trial_prompts_marketplace_uses	3	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Количество бесплатных попыток маркетплейса
828e9e43-13d6-46cf-aa4d-b9385a10ecd5	trial_covers_enabled	true	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Включить пробный период для HD обложек
ec7457c2-0b09-4e12-842e-d3646445a663	trial_covers_uses	3	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Количество бесплатных попыток HD обложек
3ebf2cca-95af-4bb9-a95a-3c88e57c2529	trial_video_enabled	true	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Включить пробный период для видео
e9d118b0-5dcd-4d2d-881f-92884ded0c40	trial_video_uses	3	2026-01-21 12:28:48.831907+00	2026-01-21 12:28:48.831907+00	Количество бесплатных попыток видео
60464df2-87bf-4598-b402-3e37d74969a8	subscriber_discount_percent	10	2026-01-21 16:39:05.162185+00	2026-01-21 16:39:05.162185+00	\N
0b13ecc4-b9f2-459c-abb0-ee844c739a8b	deposit_price_internal	0	2026-01-21 17:31:18.10347+00	2026-01-21 17:31:18.10347+00	\N
7d4a3278-9e34-471d-88c6-e42b3ed5b3fa	deposit_price_pdf	0	2026-01-21 17:31:18.10347+00	2026-01-21 17:31:18.10347+00	\N
968c3376-4e06-4810-bade-92421f341336	nris_api_url	https://api.nris.ru/v1	2026-01-21 17:31:18.10347+00	2026-01-21 17:31:18.10347+00	\N
86bcf4c6-94d9-4e1c-bd74-abc954112d7f	irma_api_url	https://api.irma.ru/v1	2026-01-21 17:31:18.10347+00	2026-01-21 17:31:18.10347+00	\N
f21e4717-3cc7-4b15-a33e-8f3e24378187	forum_max_post_length	50000	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Макс. длина поста
e25a3ecf-0a9b-4d2a-af97-f344cedfcbf5	forum_max_file_size	10	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Макс. размер файла (МБ)
e9b079d8-98ef-442d-8c56-919c744c8e45	forum_downvote_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл downvote
0662a8ed-d57e-4916-a170-41c0964da04b	forum_reactions_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл emoji-реакции
458afebb-effe-4219-950d-10c6998c21c5	forum_solutions_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл лучший ответ
bf95f632-c9fe-4484-9e38-1bad6e66430d	deposit_price_nris	2200	2026-01-21 19:05:55.136224+00	2026-01-21 17:31:18.10347+00	\N
6e97035f-4758-4f3d-9464-0b3243f3a64a	voting_duration_days	7	2026-01-24 22:16:53.422259+00	2026-01-24 22:16:53.422259+00	Длительность голосования в днях
92cd5761-49ca-4854-b98b-c10025de4eb2	voting_min_votes	10	2026-01-24 22:16:53.422259+00	2026-01-24 22:16:53.422259+00	Минимальное количество голосов для принятия решения
978229c5-9f6a-448b-b5a4-3a8b77183854	voting_approval_ratio	0.6	2026-01-24 22:16:53.422259+00	2026-01-24 22:16:53.422259+00	Минимальный процент лайков для одобрения (0.6 = 60%)
09283ffe-72f7-469a-ae83-6bc7a96a4100	voting_auto_approve	true	2026-01-24 22:16:53.422259+00	2026-01-24 22:16:53.422259+00	Автоматически одобрять после достижения порога
73d8d07f-126e-4fcc-ab3f-56ed30ddb7d7	deposit_price_irma	2500	2026-01-21 19:06:06.129959+00	2026-01-21 17:31:18.10347+00	\N
addc9bfb-a2b9-4641-a808-5f6e61bfc67b	copyright_check_on_upload	true	2026-01-21 19:07:14.823441+00	2026-01-21 19:07:14.823441+00	\N
dcb7600a-c61b-4027-b99d-d89b64decacf	voting_notify_artist	true	2026-01-24 22:16:53.422259+00	2026-01-24 22:16:53.422259+00	Уведомлять артиста о начале/окончании голосования
22a337e0-52d1-4df4-982a-1ed7d70be1ba	forum_trust_levels_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл систему уровней
9a61333f-3e49-4bec-9df3-5833cf596738	forum_realtime_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл realtime
bc89581b-5c2f-4707-a5a2-5ee4a3835e48	forum_automod_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Вкл/выкл автомодерацию
99118fe2-f956-4fc7-a0cd-88892717cb69	forum_auto_topics_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Автотемы для треков
e8ac8655-1acf-4c7d-9aee-406c32a502c4	forum_timecodes_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Тайм-коды в постах
6d64e87d-9b11-4c9a-b120-51f1cf6b4f12	forum_notifications_enabled	true	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Уведомления форума
caac2975-9df2-4554-9565-6ea52abea297	maintenance_mode	true	2026-02-15 17:22:43.658+00	2026-02-14 21:32:34.165728+00	\N
545d4cca-07ff-43d3-9581-1501d061e151	forum_rate_limit_per_minute	3	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Лимит постов в минуту
c8190e2e-24b1-402e-b152-5634d18a4328	forum_post_cooldown_seconds	15	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Кулдаун между постами
33a5ecc8-4cc0-4107-9910-824023045267	forum_auto_hide_threshold	5	2026-02-07 11:33:32.7547+00	2026-02-07 11:33:32.7547+00	Жалоб для автоскрытия
28e0d705-c2c6-4bd9-b8e0-3fe6f5de9f96	voting_rate_limit_per_hour	20	2026-02-15 01:27:22.772785+00	2026-02-15 01:27:22.772785+00	???????????????? ?????????????? ?? ?????? ???? ???????????? ????????????????????????
2e0a42db-f6df-4445-b850-bc14afdf52de	voting_min_account_age_hours	24	2026-02-15 01:27:22.772785+00	2026-02-15 01:27:22.772785+00	?????????????????????? ?????????????? ???????????????? ?????? ?????????????????????? (????????)
673b4982-a927-4769-a037-ad4c5a0592a5	maintenance_eta	2026-03-02T09:00:00.000Z	2026-02-15 17:22:33.951+00	2026-02-14 21:32:34.165728+00	\N
\.


--
-- Data for Name: store_beats; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.store_beats (id, user_id, track_id, title, description, price, license_type, is_active, sales_count, tags, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: store_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.store_items (id, user_id, type, title, description, price, cover_url, file_url, category, tags, is_active, sales_count, created_at, updated_at, genre_id, is_exclusive, item_type, license_terms, license_type, preview_url, seller_id, source_id, views_count) FROM stdin;
\.


--
-- Data for Name: subscription_plans; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.subscription_plans (id, name, name_ru, description, price_monthly, price_yearly, features, daily_generations, is_active, sort_order, created_at, badge_emoji, commercial_license, generation_credits, no_watermark, priority_generation, service_quotas, updated_at) FROM stdin;
fe73b64e-ec22-44fc-acdc-be91de13c35c	free	Бесплатный	\N	0	0	[]	5	t	0	2026-02-13 12:19:42.995764+00	\N	f	0	f	f	{}	2026-02-14 21:32:34.175165+00
3249ee6b-d760-48e1-b3a2-6733a04dd07d	premium	Премиум	\N	599	0	[]	50	t	2	2026-02-13 12:19:42.995764+00	\N	f	0	f	f	{}	2026-02-14 21:32:34.175165+00
d604318a-660b-484c-a2fd-32963bcfd62a	pro	PRO	\N	999	0	[]	100	t	3	2026-02-13 12:19:42.995764+00	\N	f	0	f	f	{}	2026-02-14 21:32:34.175165+00
f3e6bbfc-6839-45f6-9aeb-7e9a3eec3839	basic	Базовый	\N	399	3999	[]	20	t	1	2026-02-13 12:19:42.995764+00	\N	f	3	f	f	{"boost_style": 3, "create_prompt": 3, "generate_lyrics": 3}	2026-02-14 21:32:34.175165+00
\.


--
-- Data for Name: support_messages; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.support_messages (id, ticket_id, user_id, message, is_staff, created_at) FROM stdin;
\.


--
-- Data for Name: support_tickets; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.support_tickets (id, user_id, subject, message, status, priority, category, assigned_to, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: system_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.system_settings (id, key, value, description, updated_at) FROM stdin;
f6019c8e-a4d8-4768-b4b3-eb5e1d80c3f6	maintenance	{"enabled": false, "message": ""}	Режим обслуживания	2026-02-13 12:06:39.093845+00
97f0b42f-7966-4741-9d6d-272af22fc5a9	registration	{"enabled": true, "require_invite": false}	Настройки регистрации	2026-02-13 12:06:39.093845+00
2f05e105-c974-4a11-bc8d-ff5af33d7257	generation	{"daily_limit_free": 5, "daily_limit_premium": 50}	Лимиты генерации	2026-02-13 12:06:39.093845+00
d1fac9a1-1098-42d1-b4ed-2b5c933471f8	payments	{"yookassa_enabled": false, "robokassa_enabled": false}	Настройки платежей	2026-02-13 12:06:39.093845+00
\.


--
-- Data for Name: templates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.templates (id, name, description, prompt_template, is_active, sort_order, created_at) FROM stdin;
0a790aa5-be20-4c66-9031-04f64c6e81c7	Поп-хит	Запоминающийся поп-хит с припевом	\N	t	1	2026-02-13 11:52:25.392125+00
e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	Баллада	Медленная эмоциональная композиция	\N	t	2	2026-02-13 11:52:25.392125+00
9fc30e82-41b4-45b1-83b5-b29cb04b7cdb	Танцевальный	Энергичный танцевальный трек	\N	t	3	2026-02-13 11:52:25.392125+00
fd14891a-09e4-4b00-86c9-61308f25ab20	Рок-гимн	Мощный рок-трек	\N	t	4	2026-02-13 11:52:25.392125+00
880298c3-632f-4d0f-98fa-52c35dfd396c	Хип-хоп бит	Современный хип-хоп бит	\N	t	5	2026-02-13 11:52:25.392125+00
\.


--
-- Data for Name: ticket_messages; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ticket_messages (id, ticket_id, user_id, message, is_staff, attachment_url, created_at) FROM stdin;
\.


--
-- Data for Name: track_addons; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_addons (id, track_id, user_id, addon_service_id, status, result_url, metadata, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: track_bookmarks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_bookmarks (id, user_id, track_id, created_at) FROM stdin;
14c2e93c-8d31-4616-bc00-cfbffc3b707d	a0000000-0000-0000-0000-000000000001	376aa628-eafd-48a3-9d11-f46e81c99eb3	2026-02-14 23:26:51.26242+00
dd307305-827b-446d-b1ec-6ca846dc200e	a0000000-0000-0000-0000-000000000001	6ea24ec5-3965-42f9-aa7f-c20c1799fac0	2026-02-15 19:44:31.473772+00
a0d4bddb-9f1a-418d-8af3-ff7af352c4e2	fe67116b-0ad9-4491-9670-f40d1939db1e	75cb5238-e896-409e-9553-d8c8522033c3	2026-02-15 20:36:30.815024+00
f5f65cd7-eafd-4ab4-8357-125c4acad56e	955ff6c1-f3db-4087-8e68-cb67ffc41862	e825e782-f8c4-4a44-803b-b0faf74c9762	2026-02-16 00:57:37.102684+00
\.


--
-- Data for Name: track_comments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_comments (id, track_id, user_id, content, parent_id, likes_count, created_at, updated_at, is_pinned, is_hidden, timestamp_seconds, quote_text, quote_author) FROM stdin;
\.


--
-- Data for Name: track_daily_stats; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_daily_stats (id, track_id, date, plays, likes, downloads, shares, comments, created_at) FROM stdin;
\.


--
-- Data for Name: track_deposits; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_deposits (id, user_id, track_id, amount, status, payment_id, created_at, method, completed_at, file_hash, metadata_hash, certificate_url, blockchain_tx_id, external_deposit_id, external_certificate_url, error_message, performer_name, lyrics_author) FROM stdin;
5991d58b-0137-4726-b14f-3312d742d7cb	955ff6c1-f3db-4087-8e68-cb67ffc41862	92009d5e-9657-4d91-a402-e29cfc1a4bc9	0	failed	\N	2026-02-15 21:42:28.84189+00	blockchain	\N	9c441c607aa9f26d147bd992d6747ab2cd8bd384a595c10393edf0a231785ffe	ea61aa681b09beeaea6fa88199bd12897cb88c88ad3210b872156c0fb16a4b2f	\N	\N	\N	\N	Cannot read properties of undefined (reading 'replace')	йцуйцуй	уйцуйцуйцуйцу
b689cec1-1bc0-4e25-b588-57c3a35dbf12	955ff6c1-f3db-4087-8e68-cb67ffc41862	666e95a3-d230-42d0-87ce-3081a0cc299d	0	completed	\N	2026-02-15 21:46:40.744233+00	blockchain	2026-02-15 21:46:42.005+00	296e9e3aae39d8f11aaceb7d25f992ec3c3cb6e37de723c39b023b9eb2192c4b	7e245c551a49e77085fc1f43d0d464cef152738d12fbfdec2fd4b40812523984	http://api:3000/storage/v1/object/public/certificates/certificate_b689cec1-1bc0-4e25-b588-57c3a35dbf12.html?download=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D1%81%D0%BA%D0%BE%D0%B5_%D1%81%D0%B2%D0%B8%D0%B4%D0%B5%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%BE_%D0%91%D0%B5%D0%B7%20%D0%BD%D0%B0%D0%B7%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F.html	ots_1771192001983	\N	\N	\N	аывавыапвыапыва	ывапывапывапыва
73344c4d-1648-4fc0-9a5e-cf12e270ddd2	955ff6c1-f3db-4087-8e68-cb67ffc41862	a90a39d1-7041-40c5-9ec1-c3984a962df3	0	completed	\N	2026-02-15 22:00:55.693359+00	blockchain	2026-02-15 22:00:56.967+00	45efbc1abc85098f9b9a7718b5e279d78e78ff63f0f7aa776a5fa50d9fe42096	a591bf1a8eb2fbb9c4ea676aabd85951546ddababe725c35b0bb53bfac57bc7d	https://aimuza.ru/storage/v1/object/public/certificates/certificate_73344c4d-1648-4fc0-9a5e-cf12e270ddd2.html?download=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D1%81%D0%BA%D0%BE%D0%B5_%D1%81%D0%B2%D0%B8%D0%B4%D0%B5%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%BE_%D0%91%D0%B5%D0%B7%20%D0%BD%D0%B0%D0%B7%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F.html	ots_1771192856941	\N	\N	\N	111111111111	3333333333333
15998019-cb1a-4861-a932-d5593bb94f53	955ff6c1-f3db-4087-8e68-cb67ffc41862	62ba5a2a-20e6-4cff-bd09-1e5da9459cab	0	completed	\N	2026-02-15 22:10:57.053818+00	blockchain	2026-02-15 22:10:58.299+00	0b7669d7383f8267b9c9b77149b27a38fc899ea31f293d6df7d75ca340089699	0aec35b04563c524b3615117bfd52f60464c36de67fdc13b602e00cc19fb1a07	https://aimuza.ru/storage/v1/object/public/certificates/certificate_15998019-cb1a-4861-a932-d5593bb94f53.html?download=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D1%81%D0%BA%D0%BE%D0%B5_%D1%81%D0%B2%D0%B8%D0%B4%D0%B5%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%BE_%D0%91%D0%B5%D0%B7%20%D0%BD%D0%B0%D0%B7%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F.html	ots_1771193458278	\N	\N	\N	ыфавфыва	ыфвафывафыва
8b9af173-5bfd-4c2b-8a2e-dd80e7480f4a	955ff6c1-f3db-4087-8e68-cb67ffc41862	fc7b314a-bc3b-4dca-b852-3ce42a10b4f9	0	completed	\N	2026-02-15 22:21:48.340125+00	blockchain	2026-02-15 22:21:49.713+00	ee59d6e97c2fe60376ff549cdbd190d64d1db381311ea4dc808dc55479742733	247510cc1c10d14e4b6c7716803a049a5003af6e471707a6cc5d8e0b773cbffd	https://aimuza.ru/storage/v1/object/public/certificates/certificate_8b9af173-5bfd-4c2b-8a2e-dd80e7480f4a.html?download=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D1%81%D0%BA%D0%BE%D0%B5_%D1%81%D0%B2%D0%B8%D0%B4%D0%B5%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%BE_%D0%91%D0%B5%D0%B7%20%D0%BD%D0%B0%D0%B7%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F.html	ots_1771194109704	\N	\N	\N	ывапывапвы	выапывапвыап
2e8baff3-528f-4943-895b-f435e53e511c	955ff6c1-f3db-4087-8e68-cb67ffc41862	38f07fea-ea94-4072-ae24-ac6bb45308cf	0	completed	\N	2026-02-15 23:05:23.020406+00	blockchain	2026-02-15 23:05:24.73+00	5c5ab8d71172bf6093ee693d274a2ec16a33e407fa06f50ff37fefc79d48cc14	d0622b583ce641354a9fe07a180be5045cf6c6ade550a9a41398c8d677a85f8d	https://aimuza.ru/storage/v1/object/public/certificates/certificate_2e8baff3-528f-4943-895b-f435e53e511c.html?download=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D1%81%D0%BA%D0%BE%D0%B5_%D1%81%D0%B2%D0%B8%D0%B4%D0%B5%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%BE_%D0%91%D0%B5%D0%B7%20%D0%BD%D0%B0%D0%B7%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F.html	ots_1771196724721	\N	\N	\N	ыфваыфва	ыфваыфваыфв
\.


--
-- Data for Name: track_feed_scores; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_feed_scores (track_id, raw_engagement, weighted_engagement, velocity_1h, velocity_24h, time_decay_factor, final_score, stream_eligible, is_spam, calculated_at) FROM stdin;
\.


--
-- Data for Name: track_health_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_health_reports (id, track_id, check_type, status, details, created_at) FROM stdin;
\.


--
-- Data for Name: track_likes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_likes (id, user_id, track_id, created_at) FROM stdin;
7198e4b5-c0b4-42d8-b980-26b51c683d88	a0000000-0000-0000-0000-000000000001	376aa628-eafd-48a3-9d11-f46e81c99eb3	2026-02-14 23:26:48.847941+00
d7fd76fd-7548-4f59-a9bb-ef4ab0938455	a0000000-0000-0000-0000-000000000001	a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	2026-02-15 19:37:29.232401+00
9a0a20e9-e70d-4d8a-ae3a-551aa5d2e1f7	a0000000-0000-0000-0000-000000000001	2200c86c-1f8e-4eb6-badc-1c501e3fd526	2026-02-15 19:37:40.046415+00
8315df48-bd8b-4996-97d0-9fef4d43af08	a0000000-0000-0000-0000-000000000001	6ea24ec5-3965-42f9-aa7f-c20c1799fac0	2026-02-15 19:37:53.558402+00
199a8124-74ff-4b96-b23d-7a786f2ff3ee	a0000000-0000-0000-0000-000000000001	666e95a3-d230-42d0-87ce-3081a0cc299d	2026-02-15 19:37:57.829806+00
5dcc0fc3-2e09-44dc-b835-480a1949eaf4	955ff6c1-f3db-4087-8e68-cb67ffc41862	e825e782-f8c4-4a44-803b-b0faf74c9762	2026-02-16 00:57:46.729835+00
d361af7f-a8e6-4be0-b27e-15884f8435b1	fe67116b-0ad9-4491-9670-f40d1939db1e	7908bd88-deb7-4adf-9cce-281c223adbb0	2026-02-16 16:53:30.579779+00
3bce1c95-9bd8-4e82-8dce-243d8aa41569	fe67116b-0ad9-4491-9670-f40d1939db1e	453990ea-7572-4a36-a463-d1b339a6be73	2026-02-16 16:59:52.753969+00
c654f281-44ac-4197-b142-ec88ff9b705e	fe67116b-0ad9-4491-9670-f40d1939db1e	f05bf03f-bfc2-41ec-8ea4-edef3bb79b36	2026-02-16 19:18:54.244208+00
00b20d48-fe48-49d4-aa16-902f762e9a64	fe67116b-0ad9-4491-9670-f40d1939db1e	3fd49c1b-5f36-48fe-b2c0-4598653d28d8	2026-02-16 19:22:39.762132+00
e6d9d8ea-5e42-4745-b8f1-c7b16b1af227	fe67116b-0ad9-4491-9670-f40d1939db1e	756f24ca-6559-4339-a6c8-5e31e046c539	2026-02-16 19:29:32.322457+00
bdbe264e-e608-487e-887d-8faaecacba26	fe67116b-0ad9-4491-9670-f40d1939db1e	cb0e26d1-a3ab-4551-8476-991a0940fe2e	2026-02-16 19:30:07.386161+00
\.


--
-- Data for Name: track_promotions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_promotions (id, track_id, user_id, type, status, amount, impressions, clicks, starts_at, ends_at, created_at, expires_at, boost_type) FROM stdin;
\.


--
-- Data for Name: track_quality_scores; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_quality_scores (id, track_id, user_id, engagement_rate, completion_rate, unique_listeners_48h, save_rate, skip_rate, replay_rate, quality_score, eligible_for_feed, eligible_for_attribution, flagged_as_spam, metrics_collected_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: track_reactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_reactions (id, track_id, user_id, reaction_type, created_at) FROM stdin;
\.


--
-- Data for Name: track_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_reports (id, track_id, reporter_id, reason, status, reviewed_by, reviewed_at, created_at) FROM stdin;
\.


--
-- Data for Name: track_votes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.track_votes (id, track_id, user_id, vote_type, created_at, comment) FROM stdin;
e1939bb2-e387-4918-b2ff-17d92173c5f1	877a4bd9-5c2a-44a8-8082-699113dfd91e	a0000000-0000-0000-0000-000000000001	like	2026-02-15 01:32:53.649022+00	\N
ddd507c5-f9f2-415f-a5cf-f72c379c7703	b6baa477-fa9a-4560-86d5-534d33843e69	955ff6c1-f3db-4087-8e68-cb67ffc41862	like	2026-02-15 19:38:29.898742+00	\N
ebaf209a-cb36-4acd-80bb-e44b12230424	b6baa477-fa9a-4560-86d5-534d33843e69	fe67116b-0ad9-4491-9670-f40d1939db1e	like	2026-02-16 19:23:25.178032+00	\N
\.


--
-- Data for Name: tracks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.tracks (id, user_id, title, description, lyrics, audio_url, cover_url, duration, genre_id, model_id, vocal_type_id, template_id, artist_style_id, is_public, likes_count, plays_count, status, created_at, updated_at, moderation_status, source_type, distribution_status, voting_started_at, voting_ends_at, voting_likes_count, voting_dislikes_count, voting_result, voting_type, prompt_text, tags, bpm, key_signature, suno_id, video_url, is_boosted, boost_expires_at, downloads_count, shares_count, share_token, copyright_check_status, copyright_check_result, copyright_checked_at, plagiarism_check_status, plagiarism_check_result, is_original_work, has_samples, samples_licensed, performer_name, label_name, wav_url, master_audio_url, certificate_url, contest_winner_badge, moderation_reviewed_by, moderation_rejection_reason, moderation_notes, moderation_reviewed_at, forum_topic_id, error_message, "position", audio_reference_url, blockchain_hash, distribution_approved_at, distribution_approved_by, distribution_platforms, distribution_rejection_reason, distribution_requested_at, distribution_reviewed_at, distribution_reviewed_by, distribution_submitted_at, gold_pack_url, has_interpolations, interpolations_licensed, isrc_code, lufs_normalized, lyrics_author, master_uploaded_at, metadata_cleaned, music_author, processing_completed_at, processing_progress, processing_stage, processing_started_at, suno_audio_id, upscale_detected) FROM stdin;
056da0db-8a45-43d7-8dc8-4ae36dee4d7c	955ff6c1-f3db-4087-8e68-cb67ffc41862	Снова пьют (v2)	russian folk rock, melancholic male vocals, acoustic guitar, harmonica, nostalgic, slow tempo, minor key, winter atmosphere\n\n[task_id: 6c88691ef1baba23a190e3234b4a37c9]\n\n[task_id: 6c88691ef1baba23a190e3234b4a37c9]	[Intro] [Acoustic guitar arpeggio, melancholic, slow tempo, minor key]\n[Harmonica solo, nostalgic, winter atmosphere]\n\n[Verse 1] [Male Vocal, melancholic, soft]\nСнова пьют здесь, дерутся и плачут\nПод гармоники жёлтый разлив.\nЯ не мог в этой жизни иначе,\nСердце в поле своё уронив.\n\n[Verse 2] [Male Vocal, melancholic, acoustic guitar strumming]\nЗолотая, дремучая куща,\nГде в оврагах скрывается дым,\nЯ всё тот же — беспутный, заблудший,\nНо душою навек молодым.\n\n[Chorus] [Male Vocal, emotional, harmonica accents]\nПусть поёт мне метель про измену,\nПусть кобыла бьёт в лужу копытом —\nЯ целую родные колена\nУ березы, ветрами побитой.\n\n[Verse 3] [Male Vocal, melancholic, soft, reflective]\nНе жалею, не зову, не плачу...\nТолько жаль — отцвела голова.\nЯ копейку последнюю сдачи\nПроменял на хмельные слова.\n\n[Chorus] [Male Vocal, emotional, powerful, harmonica and guitar swell]\nПусть поёт мне метель про измену,\nПусть кобыла бьёт в лужу копытом —\nЯ целую родные колена\nУ березы, ветрами побитой.\n\n[Bridge]	https://aimuza.ru/storage/v1/object/public/tracks/audio/056da0db-8a45-43d7-8dc8-4ae36dee4d7c.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/056da0db-8a45-43d7-8dc8-4ae36dee4d7c.jpg	\N	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-16 00:28:22.563799+00	2026-02-16 00:33:37.131393+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	a87977d9-ad16-42c9-8e18-5cf7e044ed22	f
a797ff70-db6f-42e5-aad0-5ef7b5d5f1d1	955ff6c1-f3db-4087-8e68-cb67ffc41862	Снова пьют (v1)	russian folk rock, melancholic male vocals, acoustic guitar, harmonica, nostalgic, slow tempo, minor key, winter atmosphere\n\n[task_id: 6c88691ef1baba23a190e3234b4a37c9]\n\n[task_id: 6c88691ef1baba23a190e3234b4a37c9]	[Intro] [Acoustic guitar arpeggio, melancholic, slow tempo, minor key]\n[Harmonica solo, nostalgic, winter atmosphere]\n\n[Verse 1] [Male Vocal, melancholic, soft]\nСнова пьют здесь, дерутся и плачут\nПод гармоники жёлтый разлив.\nЯ не мог в этой жизни иначе,\nСердце в поле своё уронив.\n\n[Verse 2] [Male Vocal, melancholic, acoustic guitar strumming]\nЗолотая, дремучая куща,\nГде в оврагах скрывается дым,\nЯ всё тот же — беспутный, заблудший,\nНо душою навек молодым.\n\n[Chorus] [Male Vocal, emotional, harmonica accents]\nПусть поёт мне метель про измену,\nПусть кобыла бьёт в лужу копытом —\nЯ целую родные колена\nУ березы, ветрами побитой.\n\n[Verse 3] [Male Vocal, melancholic, soft, reflective]\nНе жалею, не зову, не плачу...\nТолько жаль — отцвела голова.\nЯ копейку последнюю сдачи\nПроменял на хмельные слова.\n\n[Chorus] [Male Vocal, emotional, powerful, harmonica and guitar swell]\nПусть поёт мне метель про измену,\nПусть кобыла бьёт в лужу копытом —\nЯ целую родные колена\nУ березы, ветрами побитой.\n\n[Bridge]	https://aimuza.ru/storage/v1/object/public/tracks/audio/a797ff70-db6f-42e5-aad0-5ef7b5d5f1d1.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a797ff70-db6f-42e5-aad0-5ef7b5d5f1d1.jpg	240	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-16 00:28:22.563799+00	2026-02-16 00:33:37.37273+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	42bb4626-2eda-4c97-afa3-9c407b4bf4d0	f
19335f0d-93a0-489e-8534-8239fe2ea096	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	Modern Russian chanson, clean production, acoustic guitar, professional male vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity, smooth baritone crooner vocals, velvety, Frank Sinatra style, elegant, warm depth\n\n[task_id: e9d46ed211d4ac3e40837af903f4f8ba]\n\n[task_id: e9d46ed211d4ac3e40837af903f4f8ba]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/19335f0d-93a0-489e-8534-8239fe2ea096.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/19335f0d-93a0-489e-8534-8239fe2ea096.jpg	240	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-15 20:23:02.758054+00	2026-02-15 20:25:24.2636+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	446ef95e-4af4-40ed-ae47-bd8ab75e55ea	f
d8a9c2f3-e229-41b6-a33d-efea4b3a7001	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	The modern Russian chanson opens with crisp acoustic guitar, joined by a warm, understated accordion that weaves in and out. Professional male vocals sit prominently in the mix, surrounded by natural reverb. The clean, high-fidelity production preserves a heartfelt, intimate atmosphere.\n\n[task_id: f42942d2463c3dc7b65bc6a8df98adee]\n\n[task_id: f42942d2463c3dc7b65bc6a8df98adee]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/d8a9c2f3-e229-41b6-a33d-efea4b3a7001.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d8a9c2f3-e229-41b6-a33d-efea4b3a7001-suno-0.png	207	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:21:42.811916+00	2026-02-15 20:24:53.264102+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	984df359-6765-46e0-ba16-df06f27e14e1	f
fad15fe6-9273-43e8-9303-71791bd2898c	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	The modern Russian chanson opens with crisp acoustic guitar, joined by a warm, understated accordion that weaves in and out. Professional male vocals sit prominently in the mix, surrounded by natural reverb. The clean, high-fidelity production preserves a heartfelt, intimate atmosphere.\n\n[task_id: f42942d2463c3dc7b65bc6a8df98adee]\n\n[task_id: f42942d2463c3dc7b65bc6a8df98adee]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/fad15fe6-9273-43e8-9303-71791bd2898c.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/fad15fe6-9273-43e8-9303-71791bd2898c-suno-1.png	221	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:21:42.811916+00	2026-02-15 20:24:53.70876+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	4ab21bec-7001-499f-91a1-7fe6d081f73b	f
909e2ad8-f5b3-4b63-b258-fe748c86c54d	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: 2d1824b988fbc92d2e717a48eb5e3348]\n\n[task_id: 2d1824b988fbc92d2e717a48eb5e3348]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/909e2ad8-f5b3-4b63-b258-fe748c86c54d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/909e2ad8-f5b3-4b63-b258-fe748c86c54d.jpg	\N	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 14:15:28.061825+00	2026-02-15 14:18:20.003381+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	adf4e412-f6dc-4a53-9945-d25e6103cc3c	f
666e95a3-d230-42d0-87ce-3081a0cc299d	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v1)	[task_id: 1ef64bbfb0d6c7e914893bba5cae3c60]\n\n[task_id: 1ef64bbfb0d6c7e914893bba5cae3c60]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/666e95a3-d230-42d0-87ce-3081a0cc299d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/666e95a3-d230-42d0-87ce-3081a0cc299d.jpg	239	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	1	0	completed	2026-02-15 19:34:06.436485+00	2026-02-15 19:38:20.232567+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	e885f59f-80e6-42d2-8b69-3c89307c1903	f
a394a39c-dedd-45a0-911e-d1830d5ee047	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v1)	[task_id: 0615c324f70c14a81e88f0dad4cc29b7]\n\n[task_id: 0615c324f70c14a81e88f0dad4cc29b7]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/a394a39c-dedd-45a0-911e-d1830d5ee047.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a394a39c-dedd-45a0-911e-d1830d5ee047-suno-0.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-15 19:34:01.576186+00	2026-02-15 19:37:34.594891+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	871d6eea-89f1-449a-87f9-8b47ff0e2eb5	f
92009d5e-9657-4d91-a402-e29cfc1a4bc9	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v2)	[task_id: 0615c324f70c14a81e88f0dad4cc29b7]\n\n[task_id: 0615c324f70c14a81e88f0dad4cc29b7]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/92009d5e-9657-4d91-a402-e29cfc1a4bc9.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/92009d5e-9657-4d91-a402-e29cfc1a4bc9-suno-1.png	239	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-15 19:34:01.576186+00	2026-02-15 19:37:35.644709+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5baa1039-f73e-4652-81b7-ae854b787850	f
fc7b314a-bc3b-4dca-b852-3ce42a10b4f9	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v2)	[task_id: 2121ededb7d76bc0948e0e37eeb87bfb]\n\n[task_id: 2121ededb7d76bc0948e0e37eeb87bfb]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/fc7b314a-bc3b-4dca-b852-3ce42a10b4f9.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/fc7b314a-bc3b-4dca-b852-3ce42a10b4f9-suno-0.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:12:23.241687+00	2026-02-15 22:16:55.294208+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	8c9a74c5-b118-4a03-a196-9909ad13826e	f
38f07fea-ea94-4072-ae24-ac6bb45308cf	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v1)	[task_id: 2121ededb7d76bc0948e0e37eeb87bfb]\n\n[task_id: 2121ededb7d76bc0948e0e37eeb87bfb]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/38f07fea-ea94-4072-ae24-ac6bb45308cf.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/38f07fea-ea94-4072-ae24-ac6bb45308cf-suno-1.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:12:23.241687+00	2026-02-15 22:16:55.815613+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	a9849621-06da-4b73-a220-fe25d7401ed8	f
e6e232d0-d416-441d-b4c3-dbeef88d2eea	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v2)	[task_id: 1ef64bbfb0d6c7e914893bba5cae3c60]\n\n[task_id: 1ef64bbfb0d6c7e914893bba5cae3c60]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/e6e232d0-d416-441d-b4c3-dbeef88d2eea.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/e6e232d0-d416-441d-b4c3-dbeef88d2eea.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 19:34:06.436485+00	2026-02-15 19:38:17.26755+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	a9473856-9265-4800-873a-e7c82554f965	f
82209b44-ff09-475b-8a4a-1242fac05d65	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: dd4dda5fd567b56ff4417bf51caad037]\n\n[task_id: dd4dda5fd567b56ff4417bf51caad037]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/82209b44-ff09-475b-8a4a-1242fac05d65.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/82209b44-ff09-475b-8a4a-1242fac05d65.jpg	\N	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 20:34:16.412381+00	2026-02-15 20:38:00.010953+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	c238e1f4-98c3-4b96-b09b-df01f215a01e	f
75ffa1b3-2874-4fe1-880e-fd2ec01b9c93	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: 2d1824b988fbc92d2e717a48eb5e3348]\n\n[task_id: 2d1824b988fbc92d2e717a48eb5e3348]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/75ffa1b3-2874-4fe1-880e-fd2ec01b9c93.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/75ffa1b3-2874-4fe1-880e-fd2ec01b9c93.jpg	143	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 14:15:28.061825+00	2026-02-15 14:18:24.154204+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	e985f39f-6e4a-4b27-9922-1bac84bda9e6	f
e14bc483-7392-4341-b73a-b47fa6f4733a	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 699e2320a3c6857f96da0232bf19ae3d]\n\n[task_id: 699e2320a3c6857f96da0232bf19ae3d]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как \nСловно песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/e14bc483-7392-4341-b73a-b47fa6f4733a.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/e14bc483-7392-4341-b73a-b47fa6f4733a.jpg	166	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 08:53:22.806883+00	2026-02-16 08:55:45.906217+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	63bb370e-59cb-4f73-8b91-b1ef8e8bf622	f
0adcce70-6cfc-4238-a47c-3e2dd70b8fda	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	female vocal, Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, indie, alternative style, raw and emotive, unique phrasing\n\n[task_id: 2c527b169abb8b4903bb63ee04698afa]\n\n[task_id: 2c527b169abb8b4903bb63ee04698afa]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/0adcce70-6cfc-4238-a47c-3e2dd70b8fda.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/0adcce70-6cfc-4238-a47c-3e2dd70b8fda.jpg	138	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:33:25.858025+00	2026-02-16 19:34:55.471612+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	c8da6d34-215e-4590-905c-092b933e08d8	f
9e08dcbe-bb4b-4506-8304-41787655ed16	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 699e2320a3c6857f96da0232bf19ae3d]\n\n[task_id: 699e2320a3c6857f96da0232bf19ae3d]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как \nСловно песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/9e08dcbe-bb4b-4506-8304-41787655ed16.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/9e08dcbe-bb4b-4506-8304-41787655ed16.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 08:53:22.806883+00	2026-02-16 08:55:34.056853+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	13f12ca6-37cd-45c6-ab5d-90cfa44b5552	f
ee7e9211-f25e-4b5a-b5e5-5a633d578a22	a0000000-0000-0000-0000-000000000001	Тест редактора (v2)	new wave, fast tempo, emotional, female vocal, atmospheric, ambient, deep house\n\n[task_id: ea886bf5853007245ecb00fb353d41d1]	[Intro] [Atmospheric, ambient pads] [Deep house beat enters, fast tempo]\n[Female Vocal] [Emotional, breathy]\nВ полях ромашек, в шуме ветров,\nГде тает утро в каплях рос,\nЯ встретил взгляд — и в сердце весна,\nТы словно Русь, чиста, светла.\n\n[Pre-Chorus] [Build-up, synth arpeggios]\n[Female Vocal] [Emotional]\nЛюбовь моя — свеча во тьме,\nКак реки русские, бегу к мечте.\n\n[Chorus] [Powerful, layered harmonies] [Energetic, driving beat]\n[Female Vocal]\nРоссия — дом, где мы с тобой вдвоём,\nГде каждый миг становится огнём.\n\n[Verse 2] [Atmospheric pads return]\n[Female Vocal] [Emotional, soft]\nВ твоих глазах — озёрная глушь,\nВ улыбке — солнца сломанный луч.\nМы вместе, как Москва и Нева,\nКак эхо, что звучит едва.\n\n[Pre-Chorus] [Build-up]\n[Female Vocal] [Emotional]\nЛюбовь моя — свеча во тьме,\nКак реки русские, бегу к мечте.\n\n[Chorus] [Powerful, layered harmonies] [Energetic]\n[Female Vocal]\nРоссия — дом, где мы с тобой вдвоём,\nГде каждый миг становится огнём.\n\n[Bridge] [Atmospheric, ambient breakdown] [Soft, piano only]\n[Female Vocal] [Whisper, emotional]\nПусть годы мчатся, смывая след,\nНо наша нежность — как запрет.\nВ объятиях холодной тишины\nМы с тобой — одна вина.\n\n[Build-up] [Synth swell, beat intensifies]\n\n[Chorus] [Powerful, layered harmonies] [Energetic, full arrangement]\n[Female Vocal]\nЛюбовь моя — свеча во тьме,\nКак реки русские, бегу к мечте.\nРоссия — дом, где мы с тобой вдвоём,\nГде каждый миг становится огнём…\n\n[Outro] [Atmospheric, ambient] [Deep house beat continues, then filters out]\n[Female Vocal] [Emotional, breathy whisper]\nВ полях ромашек, в шуме ветров…\nТы — моя Русь, ты — мой улов.\n[Pads and melodic elements sustain]\n[Beat fades, leaving only ethereal pads and a final synth note]\n[Fade out]\n[End]	https://aimuza.ru/storage/v1/object/public/tracks/audio/ee7e9211-f25e-4b5a-b5e5-5a633d578a22.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/ee7e9211-f25e-4b5a-b5e5-5a633d578a22.jpg	203	\N	\N	\N	\N	\N	t	0	0	completed	2026-02-14 22:58:45.822521+00	2026-02-15 19:31:35.745698+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	8a6ce719-8e2f-451b-b94f-b216a1def3c5	f
697b5df5-1310-4e6d-80a0-934641535b9d	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 120 BPM, Atmospheric, Soulful male vocals, Reverb-drenched, Deep sub bass, Muted guitar plucks, Chillout, Sophisticated, Late night vibe, Ethereal pads, Smooth percussion.\n\n[task_id: 5bc98c6442e4279e21491770a140b3c5]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]	https://aimuza.ru/storage/v1/object/public/tracks/audio/697b5df5-1310-4e6d-80a0-934641535b9d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/697b5df5-1310-4e6d-80a0-934641535b9d.jpg	132	\N	\N	\N	\N	\N	t	0	0	completed	2026-02-14 23:15:45.033672+00	2026-02-15 19:31:33.298073+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	\N	f
376aa628-eafd-48a3-9d11-f46e81c99eb3	955ff6c1-f3db-4087-8e68-cb67ffc41862	Тест редактора	\N	\N	https://aimuza.ru/storage/v1/object/public/tracks/955ff6c1-f3db-4087-8e68-cb67ffc41862/1771111025815.mp3	\N	203	\N	\N	\N	\N	\N	t	1	0	completed	2026-02-14 23:17:04.770836+00	2026-02-14 23:26:48.874305+00	approved	uploaded	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	clean	\N	\N	clean	{"score": 100, "steps": [{"id": "acoustid", "name": "AcoustID Fingerprint", "status": "error", "database": "MusicBrainz (45M+ треков)", "matchCount": 0}, {"id": "acrcloud", "name": "ACRCloud", "status": "error", "database": "Глобальная база (100M+ треков)", "matchCount": 0}, {"id": "internal", "name": "Внутренняя база", "status": "done", "database": "AI Planet Sound", "matchCount": 0}], "isClean": true, "matches": [], "checkedAt": "2026-02-14T23:17:04.807Z", "acoustidError": "ACOUSTID_API_KEY not configured", "acrcloudError": "ACRCloud credentials not configured", "acoustidAvailable": false, "acrcloudAvailable": false}	t	f	\N	\N	\N	\N	\N	\N	\N	a0000000-0000-0000-0000-000000000001	\N	\N	2026-02-14 23:17:17.063+00	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	\N	f
d735a058-ac4f-4806-b948-7544834a51c0	955ff6c1-f3db-4087-8e68-cb67ffc41862	(Distorted guitar (v2)	Dark Industrial Phonk, Hardcore Rock, Aggressive male vocals with rasp, Distorted Bass, Phonk-Metal fusion, 140 BPM, Cinematic tension, Slavic noir.\n\n[task_id: 8310fc20353bc61bd8b6b9c995edccd4]\n\n[task_id: 8310fc20353bc61bd8b6b9c995edccd4]	[Intro]\n(Distorted guitar feedback)\n(Heavy industrial bass thumps)\n(Sound of glass shattering)\n(Whispering: "Друг мой... я болен...")\n\n[Verse 1: Gritty Spoken Word]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus: Rising Tension]\n(Drums building up)\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus: Aggressive Hard Rock / Phonk Style]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Bridge: Distorted Bass Solo]\n(Heavy distorted 808 bass)\n(Aggressi	https://aimuza.ru/storage/v1/object/public/tracks/audio/d735a058-ac4f-4806-b948-7544834a51c0.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d735a058-ac4f-4806-b948-7544834a51c0.jpg	240	ecfc90cd-274a-4be3-b87c-e655ddf30f76	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 00:35:08.388695+00	2026-02-16 00:38:37.099828+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	82fb0b13-83e7-4585-983a-8a9ae52ccfe0	f
d75cacf0-8c04-4703-bf50-f1de1fcd2650	a0000000-0000-0000-0000-000000000001	Чёрный конь 7 (8)	\N	\N	https://aimuza.ru/storage/v1/object/public/tracks/a0000000-0000-0000-0000-000000000001/1771175710195.mp3	\N	288	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-15 17:15:10.186633+00	2026-02-15 17:16:56.006318+00	pending	uploaded	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	clean	\N	\N	clean	{"score": 100, "steps": [{"id": "acoustid", "name": "AcoustID Fingerprint", "status": "error", "database": "MusicBrainz (45M+ треков)", "matchCount": 0}, {"id": "acrcloud", "name": "ACRCloud", "status": "error", "database": "Глобальная база (100M+ треков)", "matchCount": 0}, {"id": "internal", "name": "Внутренняя база", "status": "done", "database": "AI Planet Sound", "matchCount": 0}], "isClean": true, "matches": [], "checkedAt": "2026-02-15T17:15:10.221Z", "acoustidError": "ACOUSTID_API_KEY not configured", "acrcloudError": "ACRCloud credentials not configured", "acoustidAvailable": false, "acrcloudAvailable": false}	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	\N	f
877a4bd9-5c2a-44a8-8082-699113dfd91e	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1	\N	\N	https://aimuza.ru/storage/v1/object/public/tracks/955ff6c1-f3db-4087-8e68-cb67ffc41862/1771111057188.mp3	\N	179	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-14 23:17:36.111543+00	2026-02-15 00:05:56.453985+00	voting	uploaded	\N	2026-02-15 00:05:56.408201+00	2026-02-22 00:05:56.408201+00	0	0	\N	public	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	clean	\N	\N	clean	{"score": 100, "steps": [{"id": "acoustid", "name": "AcoustID Fingerprint", "status": "error", "database": "MusicBrainz (45M+ треков)", "matchCount": 0}, {"id": "acrcloud", "name": "ACRCloud", "status": "error", "database": "Глобальная база (100M+ треков)", "matchCount": 0}, {"id": "internal", "name": "Внутренняя база", "status": "done", "database": "AI Planet Sound", "matchCount": 0}], "isClean": true, "matches": [], "checkedAt": "2026-02-14T23:17:36.142Z", "acoustidError": "ACOUSTID_API_KEY not configured", "acrcloudError": "ACRCloud credentials not configured", "acoustidAvailable": false, "acrcloudAvailable": false}	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	c2d3a16c-1061-4086-b3ac-1036e9be00bc	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	\N	f
d65b1d46-fb85-4e12-894f-e8503ff36705	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: 0d8e643a4029ff26722cc3244e8c1586]\n\n[task_id: 0d8e643a4029ff26722cc3244e8c1586]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]	https://aimuza.ru/storage/v1/object/public/tracks/audio/d65b1d46-fb85-4e12-894f-e8503ff36705.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d65b1d46-fb85-4e12-894f-e8503ff36705-suno-0.png	180	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	112ce9b9-43d8-4425-a02e-a90e3ed4cb11	t	0	0	completed	2026-02-14 23:41:40.819587+00	2026-02-15 19:31:31.397146+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	888a96f2-a722-4a23-9af7-f9a133d21ccd	f
1b771abb-6bca-441a-b093-84357d01c894	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 5103e2f41d2ad1eb79ed572969ae8a06]\n\n[task_id: 5103e2f41d2ad1eb79ed572969ae8a06]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо снам своим понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nТы думал, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/1b771abb-6bca-441a-b093-84357d01c894.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1b771abb-6bca-441a-b093-84357d01c894.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:49:54.630141+00	2026-02-16 16:51:51.355657+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	353c7c77-7cbd-4952-9000-472cfc1dcda4	f
835f1059-4813-47eb-88c6-ade22a300d7e	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic Progressive, 120 BPM, Atmospheric textures, Polished production, Lush synth pads, Clean electric guitar plucks, Warm groovy bassline, Crisp percussion, Emotional vibe, High-end fidelity.\n\n[task_id: 2dd36045c17f93b94430d12360122503]\n\n[task_id: 2dd36045c17f93b94430d12360122503]	[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/835f1059-4813-47eb-88c6-ade22a300d7e.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/835f1059-4813-47eb-88c6-ade22a300d7e.jpg	\N	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-14 23:43:52.681255+00	2026-02-14 23:49:18.696659+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	dc43d96a-6af2-43c4-9968-ee93d05a32ad	f
4e620d16-6236-42d2-84b1-243f6b93c095	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v1)	[task_id: 496f2349bb8b20e5405c2deb2f60b62e]\n\n[task_id: 496f2349bb8b20e5405c2deb2f60b62e]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/4e620d16-6236-42d2-84b1-243f6b93c095.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/4e620d16-6236-42d2-84b1-243f6b93c095-suno-1.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-14 23:35:51.824264+00	2026-02-14 23:48:23.778199+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	fc75090c-d434-4ee5-a3f8-41bcfedaf0e6	f
c43442e2-28f8-4243-b4e0-d65d69d73b6f	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: 0d8e643a4029ff26722cc3244e8c1586]\n\n[task_id: 0d8e643a4029ff26722cc3244e8c1586]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]	https://aimuza.ru/storage/v1/object/public/tracks/audio/c43442e2-28f8-4243-b4e0-d65d69d73b6f.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/c43442e2-28f8-4243-b4e0-d65d69d73b6f-suno-1.png	160	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	112ce9b9-43d8-4425-a02e-a90e3ed4cb11	t	0	0	completed	2026-02-14 23:41:40.819587+00	2026-02-14 23:49:30.530518+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	e61a8919-d934-4302-b420-ca02347b62ec	f
d5e30d3a-4947-4acd-a10b-a9fc1b71e6bc	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward_Universe_Alex_Spite_-_Fading_Away_77786908	\N	\N	https://aimuza.ru/storage/v1/object/public/tracks/955ff6c1-f3db-4087-8e68-cb67ffc41862/1771176765354.mp3	\N	185	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-15 17:32:45.406019+00	2026-02-15 17:35:34.675047+00	pending	uploaded	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	clean	\N	\N	clean	{"score": 100, "steps": [{"id": "acoustid", "name": "AcoustID Fingerprint", "status": "error", "database": "MusicBrainz (45M+ треков)", "matchCount": 0}, {"id": "acrcloud", "name": "ACRCloud", "status": "error", "database": "Глобальная база (100M+ треков)", "matchCount": 0}, {"id": "internal", "name": "Внутренняя база", "status": "done", "database": "AI Planet Sound", "matchCount": 0}], "isClean": true, "matches": [], "checkedAt": "2026-02-15T17:32:45.442Z", "acoustidError": "ACOUSTID_API_KEY not configured", "acrcloudError": "ACRCloud credentials not configured", "acoustidAvailable": false, "acrcloudAvailable": false}	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	\N	f
2200c86c-1f8e-4eb6-badc-1c501e3fd526	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v2)	[task_id: 496f2349bb8b20e5405c2deb2f60b62e]\n\n[task_id: 496f2349bb8b20e5405c2deb2f60b62e]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/2200c86c-1f8e-4eb6-badc-1c501e3fd526.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/2200c86c-1f8e-4eb6-badc-1c501e3fd526-suno-0.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	1	0	completed	2026-02-14 23:35:51.824264+00	2026-02-15 19:37:40.077244+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5a5597a4-917a-454f-85e0-2107924efe1e	f
ec0f448f-97e9-403d-975e-ff38903640a3	955ff6c1-f3db-4087-8e68-cb67ffc41862	(Distorted guitar (v1)	Dark Industrial Phonk, Hardcore Rock, Aggressive male vocals with rasp, Distorted Bass, Phonk-Metal fusion, 140 BPM, Cinematic tension, Slavic noir.\n\n[task_id: 8310fc20353bc61bd8b6b9c995edccd4]\n\n[task_id: 8310fc20353bc61bd8b6b9c995edccd4]	[Intro]\n(Distorted guitar feedback)\n(Heavy industrial bass thumps)\n(Sound of glass shattering)\n(Whispering: "Друг мой... я болен...")\n\n[Verse 1: Gritty Spoken Word]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus: Rising Tension]\n(Drums building up)\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus: Aggressive Hard Rock / Phonk Style]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Bridge: Distorted Bass Solo]\n(Heavy distorted 808 bass)\n(Aggressi	https://aimuza.ru/storage/v1/object/public/tracks/audio/ec0f448f-97e9-403d-975e-ff38903640a3.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/ec0f448f-97e9-403d-975e-ff38903640a3.jpg	\N	ecfc90cd-274a-4be3-b87c-e655ddf30f76	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 00:35:08.388695+00	2026-02-16 00:39:43.554827+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	baec93b6-6d23-41e2-903f-1cdc79b1d53c	f
e2b0f974-222b-406e-a7e3-cf750b4c5a87	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v1)	industrial metal, distorted guitars, aggressive screaming vocals, dark atmosphere, heavy bass, 140 bpm, minor key, chaotic breakdown\n\n[task_id: ef9aa9d0f5da228d07e57e1def745e74]\n\n[task_id: ef9aa9d0f5da228d07e57e1def745e74]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Whisper, raspy, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Powerful, aggressive screaming vocals, distorted guitars, heavy bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Verse 2] [Shout, chaotic, dissonant guitars]\n(Текст для второго	https://aimuza.ru/storage/v1/object/public/tracks/audio/e2b0f974-222b-406e-a7e3-cf750b4c5a87.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/e2b0f974-222b-406e-a7e3-cf750b4c5a87.jpg	\N	e37e9b90-d293-47e7-acb3-a8e4ca11ace8	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 00:43:21.429611+00	2026-02-16 00:46:00.70267+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	0b2f9b2d-e99d-4b57-8659-00e9ddf42b62	f
78a229b7-1880-4276-9209-d6eb6b530a1f	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	A modern Russian chanson opens with crisp acoustic guitar, soon layered with subtle, expressive accordion accents. Professional male vocals lead, enriched by gentle natural reverb. The clean, high-fidelity production ensures warmth and intimacy, supported by delicate bass and restrained percussion.\n\n[task_id: aec401df24ef133c6064cefcf7b04cb2]\n\n[task_id: aec401df24ef133c6064cefcf7b04cb2]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/78a229b7-1880-4276-9209-d6eb6b530a1f.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/78a229b7-1880-4276-9209-d6eb6b530a1f.jpg	235	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:22:48.535867+00	2026-02-15 20:25:15.876186+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	09d06114-36b4-484e-b584-3972edcb7106	f
f2fd97b5-c96e-40c1-9ab6-ec1453869d8f	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: a18ad8db7a863cc519e8c6a8a093a69f]\n\n[task_id: a18ad8db7a863cc519e8c6a8a093a69f]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/f2fd97b5-c96e-40c1-9ab6-ec1453869d8f.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/f2fd97b5-c96e-40c1-9ab6-ec1453869d8f-suno-0.png	205	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 19:33:21.21579+00	2026-02-15 20:34:20.157932+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	7edddb82-dd5b-4995-9678-96f323045c18	f
ebe20990-f8cf-4f60-a02a-6260f880808d	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: a19aaceb9a71ee88a05a1d95fdab744f]\n\n[task_id: a19aaceb9a71ee88a05a1d95fdab744f]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/ebe20990-f8cf-4f60-a02a-6260f880808d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/ebe20990-f8cf-4f60-a02a-6260f880808d.jpg	158	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 18:28:19.316411+00	2026-02-15 18:32:26.81757+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	77bb6439-886e-4f2a-a365-4b757a25e1f9	f
6ea24ec5-3965-42f9-aa7f-c20c1799fac0	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: a18ad8db7a863cc519e8c6a8a093a69f]\n\n[task_id: a18ad8db7a863cc519e8c6a8a093a69f]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/6ea24ec5-3965-42f9-aa7f-c20c1799fac0.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/6ea24ec5-3965-42f9-aa7f-c20c1799fac0-suno-1.png	158	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	1	0	completed	2026-02-15 19:33:21.21579+00	2026-02-15 19:37:53.590909+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	02b5d5ff-fbea-4f83-bf34-c7800d098382	f
7ff0aa14-265a-4cec-ae13-ed62878b3291	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	A modern Russian chanson opens with crisp acoustic guitar, soon layered with subtle, expressive accordion accents. Professional male vocals lead, enriched by gentle natural reverb. The clean, high-fidelity production ensures warmth and intimacy, supported by delicate bass and restrained percussion.\n\n[task_id: aec401df24ef133c6064cefcf7b04cb2]\n\n[task_id: aec401df24ef133c6064cefcf7b04cb2]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/7ff0aa14-265a-4cec-ae13-ed62878b3291.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/7ff0aa14-265a-4cec-ae13-ed62878b3291.jpg	\N	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:22:48.535867+00	2026-02-15 20:25:17.946793+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	704f5109-bcd0-4616-a064-6f731ca45808	f
98ecfb00-aa0e-47c3-9b6f-2297b34d432d	a0000000-0000-0000-0000-000000000001	Deep house, melodic techno, atmospheric indie danc (v1)	[task_id: 22bceda1747c18d388612ce9bbad008c]\n\n[task_id: 22bceda1747c18d388612ce9bbad008c]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/98ecfb00-aa0e-47c3-9b6f-2297b34d432d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/98ecfb00-aa0e-47c3-9b6f-2297b34d432d.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-16 01:23:06.153533+00	2026-02-16 01:28:15.411764+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	b8c4d1f0-aa2b-4763-b3cd-3c8e94e98cb3	f
a38b1d54-d2f3-4819-9fad-72e533d40770	a0000000-0000-0000-0000-000000000001	Deep house, melodic techno, atmospheric indie danc (v2)	[task_id: 22bceda1747c18d388612ce9bbad008c]\n\n[task_id: 22bceda1747c18d388612ce9bbad008c]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/a38b1d54-d2f3-4819-9fad-72e533d40770.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a38b1d54-d2f3-4819-9fad-72e533d40770.jpg	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-16 01:23:06.153533+00	2026-02-16 01:28:15.754531+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	c57a0107-53bb-4e97-bde8-a9c256c9da40	f
8e9abfc9-109e-464f-b935-16c1bc00937a	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	Bright pop track at 120 BPM featuring vibrant synth layers, punchy electronic drums, and a crisp bass groove. The verses use rhythmic keys and light guitar plucks, leading to an ear-catching, memorabl\n\n[task_id: 660b0b79d52847110a7dd7aef3398cdb]\n\n[task_id: 660b0b79d52847110a7dd7aef3398cdb]	В переплёте из полутьмы и пылинок янтаря\nХранятся сны, что растворились к утру, не долетев до зари.\nЯ корешок их подшиваю нитями лунного света,\nА на обложке пишу дату и имя того, кому это не сбылось.	https://aimuza.ru/storage/v1/object/public/tracks/audio/8e9abfc9-109e-464f-b935-16c1bc00937a.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/8e9abfc9-109e-464f-b935-16c1bc00937a-suno-0.png	240	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-15 19:04:22.987921+00	2026-02-15 19:09:32.02981+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	559f2ebd-95fa-41f9-81d1-32dfa3bac700	f
a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1 (v2)	Deep House, Melodic House, 120 BPM, Atmospheric, Soulful male vocals, Reverb-drenched, Deep sub bass, Muted guitar plucks, Chillout, Sophisticated, Late night vibe, Ethereal pads, Smooth percussion.\n\n[task_id: a5c31428b43585c3408a70f8683dc271]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]	https://aimuza.ru/storage/v1/object/public/tracks/audio/a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9.jpg	113	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-14 23:16:16.712732+00	2026-02-15 21:02:11.825847+00	none	generated	completed	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	t	пывапывап	Нота-Фея	\N	https://aimuza.ru/output/normalized_1771189322014_vbeuura71xb.mp3	http://api:3000/storage/v1/object/public/tracks/gold-packs/a5cc9bd1-55f3-47e4-ac93-bd70ddb149f9/certificate.html	\N	\N	\N	\N	\N	\N	\N	0	\N	0x8d822c88b27d4e9b0891cd6014fa98263d53db509d003319bcd1bb926bbbfa8b	2026-02-15 20:12:15.602+00	\N	["all"]	\N	\N	2026-02-15 20:12:15.602+00	a0000000-0000-0000-0000-000000000001	2026-02-15 19:39:49.999+00	\N	f	f	\N	f	\N	2026-02-15 21:01:58.262+00	f	выапвыапвыапвыап	2026-02-15 21:02:11.824+00	100	completed	2026-02-15 21:01:57.002+00	\N	f
4549cce0-9a28-407f-b18c-45e8ffc34cf8	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	Modern Russian chanson, clean production, acoustic guitar, professional male vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity\n\n[task_id: 4532c488c811a7e715ae74a9b975c921]\n\n[task_id: 4532c488c811a7e715ae74a9b975c921]	В переплёте из полутьмы и пылинок янтаря\nЯ собираю осколки рассветов, что не смогли засиять.\nКаждый листок — обещание, каждый абзац — тишина,\nИстория, оборвавшаяся, не допетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, словно семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтобы услышал тот, кому это не сбылось, новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он хочет взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет тебе совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как ответ.\n\nЭто не архив!\nСлышишь этот пульс? Это твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/4549cce0-9a28-407f-b18c-45e8ffc34cf8.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/4549cce0-9a28-407f-b18c-45e8ffc34cf8.jpg	\N	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:16:02.835419+00	2026-02-15 20:21:51.850218+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5e6abadb-8956-4112-8e2a-fa16b63864b8	f
7e66e5c6-9bf6-4c5a-8e2c-1772d66a7995	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	Modern Russian chanson, clean production, acoustic guitar, professional male vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity\n\n[task_id: 4532c488c811a7e715ae74a9b975c921]\n\n[task_id: 4532c488c811a7e715ae74a9b975c921]	В переплёте из полутьмы и пылинок янтаря\nЯ собираю осколки рассветов, что не смогли засиять.\nКаждый листок — обещание, каждый абзац — тишина,\nИстория, оборвавшаяся, не допетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, словно семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтобы услышал тот, кому это не сбылось, новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он хочет взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет тебе совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как ответ.\n\nЭто не архив!\nСлышишь этот пульс? Это твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/7e66e5c6-9bf6-4c5a-8e2c-1772d66a7995.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/7e66e5c6-9bf6-4c5a-8e2c-1772d66a7995.jpg	217	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-15 20:16:02.835419+00	2026-02-15 20:18:28.826059+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	29149050-e408-4922-8050-ef88a505ca91	f
1c3b4810-01af-4373-a006-d9e5bbd005c7	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	[task_id: 80718c1e7591133636b5323721d43656]\n\n[task_id: 80718c1e7591133636b5323721d43656]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/1c3b4810-01af-4373-a006-d9e5bbd005c7.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1c3b4810-01af-4373-a006-d9e5bbd005c7.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:46:11.598034+00	2026-02-15 22:50:45.639649+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	4a8796ea-c39c-4849-abf3-319344dbd76c	f
45b78629-3dda-4176-9c2b-1ee6f7653c24	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	[task_id: 80718c1e7591133636b5323721d43656]\n\n[task_id: 80718c1e7591133636b5323721d43656]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/45b78629-3dda-4176-9c2b-1ee6f7653c24.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/45b78629-3dda-4176-9c2b-1ee6f7653c24.jpg	172	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:46:11.598034+00	2026-02-15 22:50:45.40191+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	8ffce050-94cd-40dc-985f-ce2547c807ad	f
a90a39d1-7041-40c5-9ec1-c3984a962df3	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v2)	[task_id: cf2e8ffeabe0e32c72247f3889b546fe]\n\n[task_id: cf2e8ffeabe0e32c72247f3889b546fe]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/a90a39d1-7041-40c5-9ec1-c3984a962df3.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a90a39d1-7041-40c5-9ec1-c3984a962df3-suno-1.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-15 21:45:13.249901+00	2026-02-15 22:12:29.479164+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	064fba10-f187-46f2-969f-aeb4251cd24b	f
62ba5a2a-20e6-4cff-bd09-1e5da9459cab	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v1)	[task_id: cf2e8ffeabe0e32c72247f3889b546fe]\n\n[task_id: cf2e8ffeabe0e32c72247f3889b546fe]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/62ba5a2a-20e6-4cff-bd09-1e5da9459cab.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/62ba5a2a-20e6-4cff-bd09-1e5da9459cab-suno-0.png	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-15 21:45:13.249901+00	2026-02-15 22:12:37.093923+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	47cd8a83-31dd-4337-a3a3-a0c95a195e33	f
0bbc1975-0903-466b-939d-fac12b7d9c32	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	Bright pop track at 120 BPM featuring vibrant synth layers, punchy electronic drums, and a crisp bass groove. The verses use rhythmic keys and light guitar plucks, leading to an ear-catching, memorabl\n\n[task_id: 660b0b79d52847110a7dd7aef3398cdb]\n\n[task_id: 660b0b79d52847110a7dd7aef3398cdb]	В переплёте из полутьмы и пылинок янтаря\nХранятся сны, что растворились к утру, не долетев до зари.\nЯ корешок их подшиваю нитями лунного света,\nА на обложке пишу дату и имя того, кому это не сбылось.	https://aimuza.ru/storage/v1/object/public/tracks/audio/0bbc1975-0903-466b-939d-fac12b7d9c32.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/0bbc1975-0903-466b-939d-fac12b7d9c32-suno-1.png	240	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-15 19:04:22.987921+00	2026-02-15 19:09:33.367349+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	29cb51bc-3377-4330-9193-76960433db72	f
a22b3a7e-fff8-4fa6-b95e-a79a844934e6	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	[task_id: 922cb9500a8dbecef21bedf033da5174]\n\n[task_id: 922cb9500a8dbecef21bedf033da5174]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/a22b3a7e-fff8-4fa6-b95e-a79a844934e6.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a22b3a7e-fff8-4fa6-b95e-a79a844934e6.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:46:56.530579+00	2026-02-15 22:49:42.862247+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	77da787f-0a8e-4699-83f0-d30b942abcb6	f
453990ea-7572-4a36-a463-d1b339a6be73	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Starts with sparse piano and organ, spotlighting commanding diva vocals. Layered gospel choir joins for lush, stacked harmonies in the chorus. Percussion and bass drive each verse as vocal acrobatics soar. Bridge features a powerful solo ad-lib section, ending with a full-band, climactic gospel finale.\n\n[task_id: 0790336a4b5aa87163e1aa4e312d439b]\n\n[task_id: 0790336a4b5aa87163e1aa4e312d439b]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, страницы тех снов закрыта \nА истории их уже списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется вновь и вновь\nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/453990ea-7572-4a36-a463-d1b339a6be73.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/453990ea-7572-4a36-a463-d1b339a6be73-suno-0.png	170	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 16:53:22.886666+00	2026-02-16 16:59:52.786549+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	65518bf7-9c3c-4305-92eb-2f383f9b39bf	f
721d6d80-f37d-49f7-9e7b-3a0f5a197f6b	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	[task_id: 827aeccbdf2abb2c88ad912ba6fab3af]\n\n[task_id: 827aeccbdf2abb2c88ad912ba6fab3af]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/721d6d80-f37d-49f7-9e7b-3a0f5a197f6b.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/721d6d80-f37d-49f7-9e7b-3a0f5a197f6b.jpg	240	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:47:43.819391+00	2026-02-15 22:50:46.092264+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5cccdf3d-4a85-4a83-a8e8-2805bc30387f	f
cd7154c5-a39a-47f3-b86f-e47a6f34ff11	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	[task_id: 922cb9500a8dbecef21bedf033da5174]\n\n[task_id: 922cb9500a8dbecef21bedf033da5174]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/cd7154c5-a39a-47f3-b86f-e47a6f34ff11.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/cd7154c5-a39a-47f3-b86f-e47a6f34ff11.jpg	213	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:46:56.530579+00	2026-02-15 22:49:39.634366+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	33b50314-b383-40a1-a5bc-a0b9a1c6ab67	f
ddfe9b15-0585-4274-ae38-8cdc1f54e3a1	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	[task_id: 827aeccbdf2abb2c88ad912ba6fab3af]\n\n[task_id: 827aeccbdf2abb2c88ad912ba6fab3af]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/ddfe9b15-0585-4274-ae38-8cdc1f54e3a1.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/ddfe9b15-0585-4274-ae38-8cdc1f54e3a1.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:47:43.819391+00	2026-02-15 22:52:33.027723+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	8915c7d2-a96c-43c7-aba0-ef1bedb8e497	f
8a6bf905-60e2-45ef-ae9d-85246b8a610d	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: a19aaceb9a71ee88a05a1d95fdab744f]\n\n[task_id: a19aaceb9a71ee88a05a1d95fdab744f]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/8a6bf905-60e2-45ef-ae9d-85246b8a610d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/8a6bf905-60e2-45ef-ae9d-85246b8a610d.jpg	\N	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 18:28:19.316411+00	2026-02-15 19:31:21.755663+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5ea4ab54-68ca-4e4b-b8cb-f911c03609d6	f
b6baa477-fa9a-4560-86d5-534d33843e69	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic Progressive, 120 BPM, Atmospheric textures, Polished production, Lush synth pads, Clean electric guitar plucks, Warm groovy bassline, Crisp percussion, Emotional vibe, High-end fidelity.\n\n[task_id: 2dd36045c17f93b94430d12360122503]\n\n[task_id: 2dd36045c17f93b94430d12360122503]	[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/b6baa477-fa9a-4560-86d5-534d33843e69.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/b6baa477-fa9a-4560-86d5-534d33843e69.jpg	163	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	t	0	0	completed	2026-02-14 23:43:52.681255+00	2026-02-15 19:31:27.758262+00	voting	generated	pending_master	2026-02-15 01:32:25.293205+00	2026-02-22 01:32:25.293205+00	0	0	\N	public	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	f	ыфывфывф	Нота-Фея	\N	https://aimuza.ru/storage/v1/object/public/tracks/a0000000-0000-0000-0000-000000000001/b6baa477-fa9a-4560-86d5-534d33843e69_master_1771165747867.wav	\N	\N	\N	\N	\N	\N	80e7c818-c672-47d8-8d51-24a7ea825578	\N	0	\N	\N	2026-02-15 14:19:47.882+00	\N	["all"]	\N	\N	2026-02-15 14:19:47.882+00	a0000000-0000-0000-0000-000000000001	2026-02-15 01:31:58.053+00	\N	f	f	\N	f	\N	2026-02-15 14:29:12.969+00	f	фывфывфы	\N	0	\N	2026-02-15 14:29:16.007+00	00ba5dea-2673-48eb-9193-f1a8e29341fa	f
d9cba561-be0e-438f-96ad-e8527811ecec	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 192f399c14276235d43564fd6a4b5016]\n\n[task_id: 192f399c14276235d43564fd6a4b5016]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как \nСловно песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/d9cba561-be0e-438f-96ad-e8527811ecec.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d9cba561-be0e-438f-96ad-e8527811ecec-suno-0.png	209	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 09:08:49.16371+00	2026-02-16 09:13:07.683821+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	c3146bbb-0c21-4c5c-9b34-127efba74f40	f
0f3faa15-ff94-4b11-ab3f-9c1dca88d489	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 192f399c14276235d43564fd6a4b5016]\n\n[task_id: 192f399c14276235d43564fd6a4b5016]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как \nСловно песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/0f3faa15-ff94-4b11-ab3f-9c1dca88d489.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/0f3faa15-ff94-4b11-ab3f-9c1dca88d489-suno-1.png	240	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 09:08:49.16371+00	2026-02-16 09:13:08.122361+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	7ee59dc3-1c8e-4acf-a436-5ca5811166e5	f
011fb1a8-cd65-4a01-9085-3a4cfbab4c54	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	[task_id: 277aebe9c9e7e1e5cd4c1dd22f3cda0c]\n\n[task_id: 277aebe9c9e7e1e5cd4c1dd22f3cda0c]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/011fb1a8-cd65-4a01-9085-3a4cfbab4c54.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/011fb1a8-cd65-4a01-9085-3a4cfbab4c54.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:52:36.420599+00	2026-02-15 22:54:53.627655+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	095e2f0e-595c-48da-83e2-e4f99d76b14f	f
1c6a77cf-1f6c-4741-b675-368f4db7964b	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	[task_id: 277aebe9c9e7e1e5cd4c1dd22f3cda0c]\n\n[task_id: 277aebe9c9e7e1e5cd4c1dd22f3cda0c]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/1c6a77cf-1f6c-4741-b675-368f4db7964b.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1c6a77cf-1f6c-4741-b675-368f4db7964b.jpg	210	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-15 22:52:36.420599+00	2026-02-15 22:54:55.037789+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	b30fd084-3324-417d-9a8e-9c5d52c9e505	f
4998c9ec-807b-41ec-b64d-b022417abc3a	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	Modern Russian chanson, clean production, acoustic guitar, professional male vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity, smooth baritone crooner vocals, velvety, Frank Sinatra style, elegant, warm depth\n\n[task_id: e9d46ed211d4ac3e40837af903f4f8ba]\n\n[task_id: e9d46ed211d4ac3e40837af903f4f8ba]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/4998c9ec-807b-41ec-b64d-b022417abc3a.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/4998c9ec-807b-41ec-b64d-b022417abc3a.jpg	\N	9038145a-b737-496c-8d78-b66c1a6f1f38	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-15 20:23:02.758054+00	2026-02-15 20:25:38.881349+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	ddb2b641-6be0-4dfa-9951-86af881e9fca	f
9ddaaf22-632a-4a3f-b717-2a0727f1cd36	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v1)	A pounding industrial metal track at 140 BPM, driven by distorted guitars, thunderous, heavily processed bass, and pounding programmed drums. Aggressive screamed vocals cut through a dense, dark atmos\n\n[task_id: f4cd627ea6c23a4c78bead7a36fd4274]\n\n[task_id: f4cd627ea6c23a4c78bead7a36fd4274]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Whisper, raspy, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Powerful, aggressive screaming vocals, distorted guitars, heavy bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Verse 2] [Shout, chaotic, dissonant guitars]\n(Текст для второго	https://aimuza.ru/storage/v1/object/public/tracks/audio/9ddaaf22-632a-4a3f-b717-2a0727f1cd36.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/9ddaaf22-632a-4a3f-b717-2a0727f1cd36.jpg	128	e37e9b90-d293-47e7-acb3-a8e4ca11ace8	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-16 00:43:31.912463+00	2026-02-16 00:55:12.831791+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	6d18e9c2-f592-4bfa-8f78-cac1cf7ce191	f
05c3b53b-2bb0-4738-bde9-cabaf88f608b	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v1)	[task_id: 1a9066b2c9cd6f152ed5fa14684fedb1]\n\n[task_id: 1a9066b2c9cd6f152ed5fa14684fedb1]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/05c3b53b-2bb0-4738-bde9-cabaf88f608b.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/05c3b53b-2bb0-4738-bde9-cabaf88f608b.jpg	147	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-16 00:25:23.051268+00	2026-02-16 00:26:55.082917+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	0ca3ef78-14d2-4c12-8cef-7efc63797008	f
f0137730-9435-4295-8d26-7f6e150e6ea7	955ff6c1-f3db-4087-8e68-cb67ffc41862	Inward (v2)	[task_id: 1a9066b2c9cd6f152ed5fa14684fedb1]\n\n[task_id: 1a9066b2c9cd6f152ed5fa14684fedb1]	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/f0137730-9435-4295-8d26-7f6e150e6ea7.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/f0137730-9435-4295-8d26-7f6e150e6ea7.jpg	\N	8d4d052a-c61e-42e5-b1c4-07ecfee91459	\N	a0fd9ed8-7277-4c5f-a662-f80e4a617822	\N	\N	f	0	0	completed	2026-02-16 00:25:23.051268+00	2026-02-16 00:27:23.943711+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	fb55f1a8-563e-4575-8242-3994b22ffc09	f
75cb5238-e896-409e-9553-d8c8522033c3	fe67116b-0ad9-4491-9670-f40d1939db1e	ПРО БОГАТЫРШ	folk Slavonic, rock-ballad, epic, uplifting, drums, woodwinds, choir, warm, medieval	\N	https://aimuza.ru/storage/v1/object/public/tracks/audio/75cb5238-e896-409e-9553-d8c8522033c3.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/75cb5238-e896-409e-9553-d8c8522033c3.jpg	240	c32401d5-a08c-4b37-8b84-0fb73a0ac290	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-15 20:25:58.175008+00	2026-02-16 08:52:00.836866+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	46003bdb-d1d3-4136-92dc-2c9c76b966ae	f
d7a30a02-757d-48b2-979e-6a20166587a8	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 18b3d10fe11c4a5505acccc6eaa56943]\n\n[task_id: 18b3d10fe11c4a5505acccc6eaa56943]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как лист календаря\nКак песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/d7a30a02-757d-48b2-979e-6a20166587a8.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d7a30a02-757d-48b2-979e-6a20166587a8-suno-0.png	219	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 15:18:58.605852+00	2026-02-16 15:21:57.687189+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	54d375bc-9c3f-40ad-8ff3-af9f634ba2c2	f
82aadf0f-67e0-4659-8b00-6754a1e69082	fe67116b-0ad9-4491-9670-f40d1939db1e	Библиотека забытых снов (v1)	Modern Russian chanson, clean production, acoustic guitar, professional female vocals, heartfelt lyrics, subtle accordion, natural reverb, clear vocal production, high fidelity, smooth baritone crooner vocals, velvety, Frank Sinatra style, elegant, warm depth\n\n[task_id: 7042c567a3a014783d942e940446eac0]\n\n[task_id: 7042c567a3a014783d942e940446eac0]	В переплете из полутьмы и пылинок янтаря\nСобираю осколки рассветов, что не смогли засиять.\nКаждый листок — недописанное обещание, каждый абзац — тишина,\nИстория, оборвавшаяся на полуслове, недопетая до конца.\n\nНо я не архивариус печали, я — картограф иной земли,\nГде эти сны, как запекшиеся семена, прорастают внутри.\nЯ дам им ритм, я дам им свет, я дам им басовый удар,\nЧтоб услышал тот, кому это не сбылось, — отсюда новый старт.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/82aadf0f-67e0-4659-8b00-6754a1e69082.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/82aadf0f-67e0-4659-8b00-6754a1e69082.jpg	\N	a3e3b81a-112c-403e-8a8b-78e8eb438912	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	e9ec682c-77ac-4c83-9e86-aadbbfcb25e6	\N	f	0	0	completed	2026-02-15 20:25:58.175008+00	2026-02-15 20:28:43.170458+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	f37ef172-7a82-4ef5-a46a-c6b876a5ded0	f
a77ad808-fb29-4632-ae70-10e5fee26a42	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	Deep House, Melodic House, 118 BPM. Atmospheric and melancholic mood, soulful male vocals with heavy reverb and delay (fading effect). Deep groovy sub-bass, crisp organic percussion, soft kick drum. Shimmering pads, rhythmic muted guitar pluck, ethereal synth textures. Introspective, sophisticated, late-night driving vibe, smooth transitions, spatial depth. High-quality production, 4K audio fideli\n\n[task_id: dd4dda5fd567b56ff4417bf51caad037]\n\n[task_id: dd4dda5fd567b56ff4417bf51caad037]	[Intro: Atmospheric pads and distant percussion]\n[Verse]\nWalking through the shadows...\nWatching memories fade...\nEvery breath is hollow...\nIn this game we played...\n[Chorus: Emotional and airy]\nFading away... from the light...\nFading away... into the night...\n[Drop: Deep bassline and rhythmic muted guitar]\n[Outro: Echoing vocals, sound of rain, slow fade out]\n[Intro: Ethereal synth swells, distant guitar echoes]\n[Build: Steady deep kick, rising atmospheric tension]\n[Drop: Full melodic groove, driving warm bass, shimmering leads]\n[Bridge: Stripped back, emotional piano chords, airy space]\n[Main Theme: Melodic fusion, sophisticated rhythm, wide soundstage]\n[Outro: Fading synth layers, final deep beat]	https://aimuza.ru/storage/v1/object/public/tracks/audio/a77ad808-fb29-4632-ae70-10e5fee26a42.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a77ad808-fb29-4632-ae70-10e5fee26a42.jpg	158	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-15 20:34:16.412381+00	2026-02-15 20:37:57.57576+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	4035388a-702a-421e-9583-ca3e2e2cd066	f
2e1d064d-68f6-4881-8d72-7d17464f32ca	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v2)	A pounding industrial metal track at 140 BPM, driven by distorted guitars, thunderous, heavily processed bass, and pounding programmed drums. Aggressive screamed vocals cut through a dense, dark atmos\n\n[task_id: f4cd627ea6c23a4c78bead7a36fd4274]\n\n[task_id: f4cd627ea6c23a4c78bead7a36fd4274]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Whisper, raspy, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Powerful, aggressive screaming vocals, distorted guitars, heavy bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Verse 2] [Shout, chaotic, dissonant guitars]\n(Текст для второго	https://aimuza.ru/storage/v1/object/public/tracks/audio/2e1d064d-68f6-4881-8d72-7d17464f32ca.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/2e1d064d-68f6-4881-8d72-7d17464f32ca.jpg	\N	e37e9b90-d293-47e7-acb3-a8e4ca11ace8	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 00:43:31.912463+00	2026-02-16 00:45:33.256231+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	461588d6-bec6-43fb-8440-6c1fc896fe74	f
b67e2bcf-ac3d-4be8-ab2e-2f64f955d69d	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v2)	industrial metal, distorted guitars, aggressive screaming vocals, dark atmosphere, heavy bass, 140 bpm, minor key, chaotic breakdown\n\n[task_id: ef9aa9d0f5da228d07e57e1def745e74]\n\n[task_id: ef9aa9d0f5da228d07e57e1def745e74]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Whisper, raspy, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Powerful, aggressive screaming vocals, distorted guitars, heavy bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельнице белая зола!\n\n[Verse 2] [Shout, chaotic, dissonant guitars]\n(Текст для второго	https://aimuza.ru/storage/v1/object/public/tracks/audio/b67e2bcf-ac3d-4be8-ab2e-2f64f955d69d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/b67e2bcf-ac3d-4be8-ab2e-2f64f955d69d.jpg	232	e37e9b90-d293-47e7-acb3-a8e4ca11ace8	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 00:43:21.429611+00	2026-02-16 00:46:01.052588+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	418f9d10-3f2d-4972-9f5d-315cff32c7ed	f
afbd5a33-9e4d-4770-bbf2-cd8d68b77806	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v2)	Dark Phonk, Aggressive Accordion Folk, Hardcore Trap, Male raspy vocals, Russian lyrics, High energy, Distorted 808 bass, 150 BPM, Cinematic tension, Slavic Cyberpunk vibe.\n\n[task_id: c5b6457515b28fa1fa297c35b757bb4d]\n\n[task_id: c5b6457515b28fa1fa297c35b757bb4d]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Male Vocal] [Raspy] [Whisper, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, distorted accordion stabs, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Male Vocal] [Shout] [Powerful, aggressive screaming vocals, distorted guitars and accordion, heavy 808 bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельни	https://aimuza.ru/storage/v1/object/public/tracks/audio/afbd5a33-9e4d-4770-bbf2-cd8d68b77806.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/afbd5a33-9e4d-4770-bbf2-cd8d68b77806.jpg	240	ecfc90cd-274a-4be3-b87c-e655ddf30f76	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	0	0	completed	2026-02-16 00:48:55.26747+00	2026-02-16 00:55:01.840431+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	fdc759cf-d0f5-4402-84b9-24247f5b3621	f
22e67399-dc66-4bdd-9efb-e76dd5456acb	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 18b3d10fe11c4a5505acccc6eaa56943]\n\n[task_id: 18b3d10fe11c4a5505acccc6eaa56943]	В переплете полутьмы и янтаря\nСобираю осколки рассветов\nКаждый сон - как лист календаря\nКак песня не допетая\nЯ картограф своих снов\nКарты снов своих я читаю\nЧто сбылось, а что не сбылось\n\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/22e67399-dc66-4bdd-9efb-e76dd5456acb.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/22e67399-dc66-4bdd-9efb-e76dd5456acb-suno-1.png	207	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 15:18:58.605852+00	2026-02-16 15:21:58.139572+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	214e01f9-97fa-4c6d-a5d2-ebcbaa93696c	f
a8625d5a-7b68-47ad-8f3b-a29da950baa7	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Russian rock, melancholic, deep male vocals, 80s synthesizer, overdriven guitar, poetic atmosphere, analog warmth, authentic performance, dynamic range, high fidelity, soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f18564709d24a53bffb59d7018c74f85]\n\n[task_id: f18564709d24a53bffb59d7018c74f85]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/a8625d5a-7b68-47ad-8f3b-a29da950baa7.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a8625d5a-7b68-47ad-8f3b-a29da950baa7.jpg	182	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:20:10.870065+00	2026-02-16 17:22:39.503506+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	14616b48-fd7e-4ad7-8118-32f7277a2a4e	f
cee35d9f-9f7b-49a2-bb3e-bd96217b315c	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 99659b1a7ebf949dfb18d916025c6118]\n\n[task_id: 99659b1a7ebf949dfb18d916025c6118]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/cee35d9f-9f7b-49a2-bb3e-bd96217b315c.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/cee35d9f-9f7b-49a2-bb3e-bd96217b315c.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:27:40.512613+00	2026-02-16 19:29:56.043376+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	4dde3a4b-6249-49a8-8380-2dc6c7d00954	f
e825e782-f8c4-4a44-803b-b0faf74c9762	955ff6c1-f3db-4087-8e68-cb67ffc41862	Друг мой, (v1)	Dark Phonk, Aggressive Accordion Folk, Hardcore Trap, Male raspy vocals, Russian lyrics, High energy, Distorted 808 bass, 150 BPM, Cinematic tension, Slavic Cyberpunk vibe.\n\n[task_id: c5b6457515b28fa1fa297c35b757bb4d]\n\n[task_id: c5b6457515b28fa1fa297c35b757bb4d]	[Intro] [Industrial noise, distorted guitar feedback, breaking glass sound]\n[Verse 1] [Male Vocal] [Raspy] [Whisper, building tension]\nДруг мой, друг мой, я очень и очень болен.\nВ венах не кровь — а густой, отравленный спирт.\nЯ заперт в коробке из стали и чьей-то воли,\nГде каждый второй — в глаза мне нагло льстит.\nСлышишь? Шаги... Это он, в котелке и фраке,\nСадится на койку, костлявой рукой маня.\nОн пишет про жизнь мою в этом черном бараке,\nИ в каждой строке — он заживо ест меня!\n\n[Pre-Chorus] [Build-up, heavy bass drone, distorted accordion stabs, drums enter]\nСыпь, гармоника! Смерть — это просто звук!\nЯ выпускаю из пальцев испуганный испуг!\n\n[Chorus] [Male Vocal] [Shout] [Powerful, aggressive screaming vocals, distorted guitars and accordion, heavy 808 bass]\nЧерный человек! Хватит смотреть в упор!\nЯ заношу над тобою свой рифмованный топор!\nТы — моё отражение, ты — мой позор и бред!\nВ зеркале выжжен мой черный, больной силуэт!\nСыпь, гармоника! Больше огня и зла!\nЖизнь моя — в пепельни	https://aimuza.ru/storage/v1/object/public/tracks/audio/e825e782-f8c4-4a44-803b-b0faf74c9762.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/e825e782-f8c4-4a44-803b-b0faf74c9762.jpg	\N	ecfc90cd-274a-4be3-b87c-e655ddf30f76	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	t	1	0	completed	2026-02-16 00:48:55.26747+00	2026-02-16 00:57:46.75641+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	43a61460-dea5-4e2a-99dc-04db86913cf9	f
98364ecf-6d33-4a7a-b29e-2834911b70e9	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 854089f78761a5b6254bf691cd366233]\n\n[task_id: 854089f78761a5b6254bf691cd366233]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картограф своих дивный снов\nЯ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо страницам своих снов читаю\nПрипев:\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/98364ecf-6d33-4a7a-b29e-2834911b70e9.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/98364ecf-6d33-4a7a-b29e-2834911b70e9.jpg	195	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 15:23:08.176142+00	2026-02-16 15:25:30.639087+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	b049c762-df09-4159-a22f-622e72f0658b	f
de60de46-bfee-4eb9-9a62-5ca905cc06bb	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 854089f78761a5b6254bf691cd366233]\n\n[task_id: 854089f78761a5b6254bf691cd366233]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картограф своих дивный снов\nЯ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо страницам своих снов читаю\nПрипев:\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nЯ подшиваю не нитью, а синтов волной горячей,\nИ пылинки янтаря превращаются в искры свечей.\nПусть грусть парит на мелодии, лёгкой, как утренний дым,\nА потом растворится в бите, что стал твоим новым путём.\n\nТы думал, страница закрыта, история списана в долг?\nЯ вижу в этом начале финал для других дорог.\nТот самый сон, тот самый шёпот, что ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\nЭто не архив, это черновик!\nЭто не конец, это только мостик!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!\n\nИ пусть обложка старая помнит твоё забытое «когда»,\nНо мелодия новая пишет совсем другие слова.\nОна не стирает прошлое, она даёт новый свет,\nЧтобы тот самый сон зазвучал, как твой личный ответ.\n\nЭто не архив!\nСлышишь этот пульс? Он теперь твой!\nВидишь этот свет? Он живой!\nЯ возьму твой сон, что не долетел до зари,\nИ зажгу из него фейерверк внутри!\nЗабудь про дату, забудь про имя — бит уже бьёт!\nНовая глава начинается, вот!	https://aimuza.ru/storage/v1/object/public/tracks/audio/de60de46-bfee-4eb9-9a62-5ca905cc06bb.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/de60de46-bfee-4eb9-9a62-5ca905cc06bb.jpg	\N	67430ce4-0eed-4625-b74c-1e9cc6d8fd20	\N	52e8cc14-4905-47f4-8d2f-6d1caec54c1b	0a790aa5-be20-4c66-9031-04f64c6e81c7	\N	f	0	0	completed	2026-02-16 15:23:08.176142+00	2026-02-16 15:26:20.583312+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	ed36e4d4-b9f3-44b4-9aec-7487c99801f3	f
062d134b-5e62-4a29-b5ad-4a345a4f29d8	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v2)	melodic deep house, atmospheric indie dance, melancholic male vocals with echo, pulsing bassline, dreamy synth plucks, underwater immersion, clean sound design, 122 bpm\n\n[task_id: 38f08b19e84daec7d5d31b45364bc602]\n\n[task_id: 38f08b19e84daec7d5d31b45364bc602]	[Intro]\n(Atmospheric synth pads fading in)\n(Steady kick drum pulse)\n(Soft melodic plucks)\n\n[Verse 1: Breathy vocals]\nСнова тени ложатся на стены,\nМир застыл в ожидании сна.\nМы бежим по замерзшим венам,\nГде внутри — тишина... тишина.\n\n[Chorus: Melodic & Deep]\nУходим вглубь, за горизонты света,\nГде нет вопросов, только тихий гул.\nТам наше лето... вечное лето...\nВ котором я нечаянно утонул.\n\n[Drop: Main Synth Theme]\n(Deep rolling bassline)\n(Pluck melody with reverb)\n(Hypnotic house rhythm)\n\n[Outro]\n(Vocals fading out with delay)\n(Only bass and light percussion remaining)\n(Final synth wash)\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/062d134b-5e62-4a29-b5ad-4a345a4f29d8.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/062d134b-5e62-4a29-b5ad-4a345a4f29d8.jpg	170	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 01:10:49.19108+00	2026-02-16 01:12:32.630668+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	bda6cb22-7ca9-4bd8-bb6f-fcc9e956e42e	f
62adf583-a401-43b2-8122-54cebb8bdd7f	a0000000-0000-0000-0000-000000000001	в стиле Inward Universe (v1)	melodic deep house, atmospheric indie dance, melancholic male vocals with echo, pulsing bassline, dreamy synth plucks, underwater immersion, clean sound design, 122 bpm\n\n[task_id: 38f08b19e84daec7d5d31b45364bc602]\n\n[task_id: 38f08b19e84daec7d5d31b45364bc602]	[Intro]\n(Atmospheric synth pads fading in)\n(Steady kick drum pulse)\n(Soft melodic plucks)\n\n[Verse 1: Breathy vocals]\nСнова тени ложатся на стены,\nМир застыл в ожидании сна.\nМы бежим по замерзшим венам,\nГде внутри — тишина... тишина.\n\n[Chorus: Melodic & Deep]\nУходим вглубь, за горизонты света,\nГде нет вопросов, только тихий гул.\nТам наше лето... вечное лето...\nВ котором я нечаянно утонул.\n\n[Drop: Main Synth Theme]\n(Deep rolling bassline)\n(Pluck melody with reverb)\n(Hypnotic house rhythm)\n\n[Outro]\n(Vocals fading out with delay)\n(Only bass and light percussion remaining)\n(Final synth wash)\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/62adf583-a401-43b2-8122-54cebb8bdd7f.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/62adf583-a401-43b2-8122-54cebb8bdd7f.jpg	\N	a27e463e-d923-43f0-8aec-1857b1d51e60	\N	d16a126a-67f8-499d-91f8-1b862ad8abc8	\N	\N	f	0	0	completed	2026-02-16 01:10:49.19108+00	2026-02-16 01:13:29.855846+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	edc94b3b-06ea-4e1c-822b-d601d74a88d9	f
34df1cef-8ca8-479b-a13e-88078cf0fdfe	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v1)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 16ad486cd2c8cf30229de3400e5ced0f]\n\n[task_id: 16ad486cd2c8cf30229de3400e5ced0f]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картограф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо снам своим понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужно\nВсё-таки это забытые сны\n\nТы думал, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/34df1cef-8ca8-479b-a13e-88078cf0fdfe.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/34df1cef-8ca8-479b-a13e-88078cf0fdfe.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 15:42:55.306555+00	2026-02-16 15:45:44.583157+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	801d3397-b9e6-421a-afb0-38983c728b1c	f
c85adecf-ec38-4246-861a-13cc9d25fce2	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Russian rock, melancholic, deep male vocals, 80s synthesizer, overdriven guitar, poetic atmosphere, analog warmth, authentic performance, dynamic range, high fidelity, soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f18564709d24a53bffb59d7018c74f85]\n\n[task_id: f18564709d24a53bffb59d7018c74f85]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/c85adecf-ec38-4246-861a-13cc9d25fce2.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/c85adecf-ec38-4246-861a-13cc9d25fce2.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:20:10.870065+00	2026-02-16 17:22:38.181632+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5cb45f38-bfb3-495c-8da7-04940c8909ec	f
e546a590-1075-45ce-97b1-ed5db38f2bde	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 16ad486cd2c8cf30229de3400e5ced0f]\n\n[task_id: 16ad486cd2c8cf30229de3400e5ced0f]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картограф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо снам своим понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужно\nВсё-таки это забытые сны\n\nТы думал, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/e546a590-1075-45ce-97b1-ed5db38f2bde.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/e546a590-1075-45ce-97b1-ed5db38f2bde.jpg	137	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 15:42:55.306555+00	2026-02-16 15:45:40.960979+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	ca24448b-084f-4278-9d06-a1db21a8ee58	f
7908bd88-deb7-4adf-9cce-281c223adbb0	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v2)	powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 5103e2f41d2ad1eb79ed572969ae8a06]\n\n[task_id: 5103e2f41d2ad1eb79ed572969ae8a06]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо снам своим понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nТы думал, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/7908bd88-deb7-4adf-9cce-281c223adbb0.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/7908bd88-deb7-4adf-9cce-281c223adbb0.jpg	163	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 16:49:54.630141+00	2026-02-16 16:53:30.601206+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	882e4726-ef31-4e50-a3bb-0e3f126e79a4	f
29425820-d53a-46e7-b4cf-e945b047fd54	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v1)	Starts with sparse piano and organ, spotlighting commanding diva vocals. Layered gospel choir joins for lush, stacked harmonies in the chorus. Percussion and bass drive each verse as vocal acrobatics soar. Bridge features a powerful solo ad-lib section, ending with a full-band, climactic gospel finale.\n\n[task_id: 3002451d9d13d2a76eb0f58da4eee289]\n\n[task_id: 3002451d9d13d2a76eb0f58da4eee289]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/29425820-d53a-46e7-b4cf-e945b047fd54.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/29425820-d53a-46e7-b4cf-e945b047fd54.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:51:29.934086+00	2026-02-16 16:54:41.274195+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5fb312f6-e87f-48c8-a5c8-b0275d1a7c09	f
b94f8751-d624-40c9-b105-629f8b0fbe8b	fe67116b-0ad9-4491-9670-f40d1939db1e	Богатырша (v2)	Starts with sparse piano and organ, spotlighting commanding diva vocals. Layered gospel choir joins for lush, stacked harmonies in the chorus. Percussion and bass drive each verse as vocal acrobatics soar. Bridge features a powerful solo ad-lib section, ending with a full-band, climactic gospel finale.\n\n[task_id: 3002451d9d13d2a76eb0f58da4eee289]\n\n[task_id: 3002451d9d13d2a76eb0f58da4eee289]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, страницы тех снов закрыта \nА истории списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/b94f8751-d624-40c9-b105-629f8b0fbe8b.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/b94f8751-d624-40c9-b105-629f8b0fbe8b.jpg	178	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:51:29.934086+00	2026-02-16 16:54:42.923586+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	e6015c15-a2a2-44ee-a6e2-4b3df3f55945	f
56ec2084-4f56-4b0f-86ab-48be9a1a85fc	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Starts with sparse piano and organ, spotlighting commanding diva vocals. Layered gospel choir joins for lush, stacked harmonies in the chorus. Percussion and bass drive each verse as vocal acrobatics soar. Bridge features a powerful solo ad-lib section, ending with a full-band, climactic gospel finale.\n\n[task_id: 0790336a4b5aa87163e1aa4e312d439b]\n\n[task_id: 0790336a4b5aa87163e1aa4e312d439b]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих разных снов\nИ по снам свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, страницы тех снов закрыта \nА истории их уже списаны в долг\nЗачем нужно знать, что уже закрыто\nИ в это закрыто нет открытых дорОг\nНо есть тот самый сон не забытый\nОн повторяется вновь и вновь\nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/56ec2084-4f56-4b0f-86ab-48be9a1a85fc.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/56ec2084-4f56-4b0f-86ab-48be9a1a85fc-suno-1.png	181	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:53:22.886666+00	2026-02-16 16:57:00.696158+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	5b5f1785-d4bf-419c-b4af-f5fc58d4a095	f
3a28bab4-4ef0-4779-b918-0ade2bf0592e	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f3b6a57aeadb30918771688f55ba006a]\n\n[task_id: f3b6a57aeadb30918771688f55ba006a]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе уж никогда не напомнят\nЗабытые сны помнят что и когда\nЧто-то сбылось, а что \nНо есть один сон, мной не забытый\nОн сбылся, оставив \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/3a28bab4-4ef0-4779-b918-0ade2bf0592e.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/3a28bab4-4ef0-4779-b918-0ade2bf0592e.jpg	200	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:59:27.600079+00	2026-02-16 17:01:42.229069+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	933f881e-6dea-47e1-81e0-501937a18eba	f
2cd0892b-9731-4956-9e2a-3d40764fbc9f	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f3b6a57aeadb30918771688f55ba006a]\n\n[task_id: f3b6a57aeadb30918771688f55ba006a]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе уж никогда не напомнят\nЗабытые сны помнят что и когда\nЧто-то сбылось, а что \nНо есть один сон, мной не забытый\nОн сбылся, оставив \nчто ты сберёг в темноте,\nОн просится в танец, он рвётся взлететь в высоте.\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/2cd0892b-9731-4956-9e2a-3d40764fbc9f.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/2cd0892b-9731-4956-9e2a-3d40764fbc9f.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 16:59:27.600079+00	2026-02-16 17:02:01.095097+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	3ea34ae6-6440-4aee-ac8b-cddd75a6a83e	f
37e3eaf4-50d9-4d02-9bb3-42149c724f78	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f6231ec0f8bb4609011f8f522d192f25]\n\n[task_id: f6231ec0f8bb4609011f8f522d192f25]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  \nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/37e3eaf4-50d9-4d02-9bb3-42149c724f78.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/37e3eaf4-50d9-4d02-9bb3-42149c724f78.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:03:52.332818+00	2026-02-16 17:05:46.17543+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	3fdba635-e3de-413c-825e-44018bf0f122	f
20d43cbf-f9c4-4d0a-a7c3-817e616bab15	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: f6231ec0f8bb4609011f8f522d192f25]\n\n[task_id: f6231ec0f8bb4609011f8f522d192f25]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  \nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/20d43cbf-f9c4-4d0a-a7c3-817e616bab15.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/20d43cbf-f9c4-4d0a-a7c3-817e616bab15.jpg	170	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:03:52.332818+00	2026-02-16 17:05:47.791526+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	d2d301d6-483e-4975-86ed-0aa032ca7ae6	f
c5cd4d92-1b3e-4d86-9bd3-abc37da6f1f9	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: b19641cf1b203076f59a1f8d4d1f44c8]\n\n[task_id: b19641cf1b203076f59a1f8d4d1f44c8]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/c5cd4d92-1b3e-4d86-9bd3-abc37da6f1f9.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/c5cd4d92-1b3e-4d86-9bd3-abc37da6f1f9-suno-0.png	158	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:07:06.407111+00	2026-02-16 17:10:05.888675+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	ce5ec89a-a6ca-46bb-a988-547c77f8cbe6	f
5ad42a66-cca1-4c2c-8e2c-478f7a6af74d	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	soulful emotional female vocals, powerful delivery, gospel-inspired\n\n[task_id: b19641cf1b203076f59a1f8d4d1f44c8]\n\n[task_id: b19641cf1b203076f59a1f8d4d1f44c8]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что сбылось,  никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, тогда ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/5ad42a66-cca1-4c2c-8e2c-478f7a6af74d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/5ad42a66-cca1-4c2c-8e2c-478f7a6af74d-suno-1.png	183	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:07:06.407111+00	2026-02-16 17:10:06.442189+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	59d7f155-4f37-4816-9851-b38f8bf9ee3b	f
608d5f13-de80-4b55-a53a-fa7439dd558c	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Tempo: 75 BPM. Time signature: 4/4. Rhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.Instrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation. Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals: Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release. Dynamics and arrangement:Verses: quiet and intimate.\n\n[task_id: b9de906eac05398bc85d08e861169264]\n\n[task_id: b9de906eac05398bc85d08e861169264]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/608d5f13-de80-4b55-a53a-fa7439dd558c.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/608d5f13-de80-4b55-a53a-fa7439dd558c-suno-0.png	149	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:20:53.57762+00	2026-02-16 19:25:44.070534+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	2552e67f-d34d-4227-8f98-172478dd4731	f
c1c6a3de-ec35-4735-a797-5cdf54c4d105	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	high energy female vocals, bright, confident, pop star delivery, поп-рок\n\n[task_id: afeac12a60060a6e27a2bdf11f24d12a]\n\n[task_id: afeac12a60060a6e27a2bdf11f24d12a]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/c1c6a3de-ec35-4735-a797-5cdf54c4d105.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/c1c6a3de-ec35-4735-a797-5cdf54c4d105-suno-1.png	165	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:52:34.276805+00	2026-02-16 17:56:07.47308+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	9953c19e-701e-40e0-a7a1-9abf96db6b24	f
9b10d97c-4ef8-4f3f-b15a-a71bf6b78ed4	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	high energy female vocals, bright, confident, pop star delivery, поп-рок\n\n[task_id: ca7b13142033838269d90cf85205647b]\n\n[task_id: ca7b13142033838269d90cf85205647b]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/9b10d97c-4ef8-4f3f-b15a-a71bf6b78ed4.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/9b10d97c-4ef8-4f3f-b15a-a71bf6b78ed4.jpg	183	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:54:19.618554+00	2026-02-16 17:56:26.382096+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	9c11f87d-1b7c-42e1-ac15-8b19aea57f67	f
1a733293-c551-4519-9dcf-761f452303de	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	high energy female vocals, bright, confident, pop star delivery, поп-рок\n\n[task_id: afeac12a60060a6e27a2bdf11f24d12a]\n\n[task_id: afeac12a60060a6e27a2bdf11f24d12a]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/1a733293-c551-4519-9dcf-761f452303de.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1a733293-c551-4519-9dcf-761f452303de-suno-0.png	132	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:52:34.276805+00	2026-02-16 17:56:06.929367+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	60b7e76e-1f7c-4179-93a0-661d39a594fa	f
6dc22d29-a7f7-4654-80f6-8d07398d9f71	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	high energy female vocals, bright, confident, pop star delivery, поп-рок\n\n[task_id: ca7b13142033838269d90cf85205647b]\n\n[task_id: ca7b13142033838269d90cf85205647b]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://musicfile.removeai.ai/MjgyZmJjYzItZjUyOS00NjNlLWE1MTYtMTgxZmI4ODFiMWU4	https://aimuza.ru/storage/v1/object/public/tracks/covers/6dc22d29-a7f7-4654-80f6-8d07398d9f71.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 17:54:19.618554+00	2026-02-16 17:56:45.67867+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	282fbcc2-f529-463e-a516-181fb881b1e8	f
50c5d97e-fdab-4a68-95c8-a7d169072c4d	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	 поп-рок, high energy female vocals, bright, confident, pop star delivery,\n\n[task_id: d37f13a3f326f8632c88523696f5f805]\n\n[task_id: d37f13a3f326f8632c88523696f5f805]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/50c5d97e-fdab-4a68-95c8-a7d169072c4d.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/50c5d97e-fdab-4a68-95c8-a7d169072c4d.jpg	157	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 18:58:44.528885+00	2026-02-16 19:00:38.137309+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	17def874-7d8b-4aed-99d2-f0a89f33c413	f
1d14a4cf-c357-46a2-bbf4-d9b42321beea	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	 поп-рок, high energy female vocals, bright, confident, pop star delivery,\n\n[task_id: d37f13a3f326f8632c88523696f5f805]\n\n[task_id: d37f13a3f326f8632c88523696f5f805]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/1d14a4cf-c357-46a2-bbf4-d9b42321beea.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1d14a4cf-c357-46a2-bbf4-d9b42321beea.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 18:58:44.528885+00	2026-02-16 19:00:42.79089+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	150d1c95-7b96-48eb-983b-0d03e110427c	f
1565a785-dd3c-491c-94b3-93b12cd2e3a8	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	поп-рок, breathy airy female vocals, intimate, soft texture, delicate delivery\n\n[task_id: 8fc38edd66992a2705651121dfe99556]\n\n[task_id: 8fc38edd66992a2705651121dfe99556]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/1565a785-dd3c-491c-94b3-93b12cd2e3a8.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1565a785-dd3c-491c-94b3-93b12cd2e3a8-suno-0.png	171	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:00:46.379593+00	2026-02-16 19:04:10.448881+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	79545141-56ad-4232-a4e4-898a57ecbf1f	f
3fd49c1b-5f36-48fe-b2c0-4598653d28d8	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Tempo: 75 BPM. Time signature: 4/4.\nRhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.\nInstrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation.Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals:Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release.\nDynamics and arrangement: Verses: quiet and intimate, featuring mainly \n\n[task_id: 223dae2be1885ac4f90a9395f4afd228]\n\n[task_id: 223dae2be1885ac4f90a9395f4afd228]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/3fd49c1b-5f36-48fe-b2c0-4598653d28d8.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/3fd49c1b-5f36-48fe-b2c0-4598653d28d8.jpg	\N	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 19:13:00.515469+00	2026-02-16 19:22:39.825873+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	897b3995-f53a-4bf9-93e1-1f4e85bc8e9a	f
f05bf03f-bfc2-41ec-8ea4-edef3bb79b36	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	поп-рок, breathy airy female vocals, intimate, soft texture, delicate delivery\n\n[task_id: 8fc38edd66992a2705651121dfe99556]\n\n[task_id: 8fc38edd66992a2705651121dfe99556]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/f05bf03f-bfc2-41ec-8ea4-edef3bb79b36.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/f05bf03f-bfc2-41ec-8ea4-edef3bb79b36-suno-1.png	170	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 19:00:46.379593+00	2026-02-16 19:18:54.293366+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	9244f125-c3b0-44b2-bc13-d4515e73afcd	f
1c115a56-9294-43e3-a446-f5084d0493e1	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Tempo: 75 BPM. Time signature: 4/4.\nRhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.\nInstrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation.Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals:Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release.\nDynamics and arrangement: Verses: quiet and intimate, featuring mainly \n\n[task_id: 223dae2be1885ac4f90a9395f4afd228]\n\n[task_id: 223dae2be1885ac4f90a9395f4afd228]	В переплЁте полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыт, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nпроигрыш\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\nПроигрыш\nОкончание\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/1c115a56-9294-43e3-a446-f5084d0493e1.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/1c115a56-9294-43e3-a446-f5084d0493e1.jpg	174	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:13:00.515469+00	2026-02-16 19:15:14.823921+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	f0fc9d7a-efa9-4605-91de-5eb3521c5cd1	f
9f4605c0-846f-478a-8015-622bcf2ece3a	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Tempo: 75 BPM. Time signature: 4/4. Rhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.Instrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation. Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals: Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release. Dynamics and arrangement:Verses: quiet and intimate.\n\n[task_id: ec0d796adb5fc46a7ce159a8a9feaa8c]\n\n[task_id: ec0d796adb5fc46a7ce159a8a9feaa8c]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/9f4605c0-846f-478a-8015-622bcf2ece3a.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/9f4605c0-846f-478a-8015-622bcf2ece3a.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:20:47.990004+00	2026-02-16 19:22:58.182015+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	36fa33ab-a8f3-4751-9c8e-168620d1e416	f
ef2f2ebd-44a9-4033-91d4-fc30a82ede72	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: df9f43cc420795d6fe1a2673b6dd6967]\n\n[task_id: df9f43cc420795d6fe1a2673b6dd6967]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/ef2f2ebd-44a9-4033-91d4-fc30a82ede72.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/ef2f2ebd-44a9-4033-91d4-fc30a82ede72-suno-0.png	210	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:25:51.812718+00	2026-02-16 19:29:57.599954+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	6fe67aa7-c146-4a86-82a5-cddedaf78210	f
cb0e26d1-a3ab-4551-8476-991a0940fe2e	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Tempo: 75 BPM. Time signature: 4/4. Rhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.Instrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation. Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals: Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release. Dynamics and arrangement:Verses: quiet and intimate.\n\n[task_id: b9de906eac05398bc85d08e861169264]\n\n[task_id: b9de906eac05398bc85d08e861169264]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/cb0e26d1-a3ab-4551-8476-991a0940fe2e.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/cb0e26d1-a3ab-4551-8476-991a0940fe2e-suno-1.png	167	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 19:20:53.57762+00	2026-02-16 19:30:07.412827+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	d256783c-f05d-4417-b252-85ac50cc4657	f
12ba7485-2a92-48c9-9f85-0f0966d0a1f1	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	Tempo: 75 BPM. Time signature: 4/4. Rhythm: smooth and flowing, with accents on the weak beats (2 and 4) to create a gentle “swaying” or “rocking” effect. The rhythm should feel relaxed and lulling, not driving.Instrumentation: Acoustic guitar: fingerpicking and arpeggios throughout the track, forming the harmonic and rhythmic foundation. Soft piano: enters in the choruses to add emotional depth and richness; use gentle sustain and avoid sharp attacks. Light string section (cello and viola): subtle backing in the climactic sections (especially the final chorus) to add warmth and emotional intensity without overpowering the mix. Vocals: Voice type: female.\nStyle: tender and emotive, with a slight huskiness; convey deep feeling without forcing the sound.\nDynamics: in the verses — almost a whisper, intimate and close-miked; in the choruses — fuller and more resonant, with greater projection and emotional release. Dynamics and arrangement:Verses: quiet and intimate.\n\n[task_id: ec0d796adb5fc46a7ce159a8a9feaa8c]\n\n[task_id: ec0d796adb5fc46a7ce159a8a9feaa8c]	В лабиринтах полутьмЫ и янтарЯ\nСобираю я осколки рассветов\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/12ba7485-2a92-48c9-9f85-0f0966d0a1f1.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/12ba7485-2a92-48c9-9f85-0f0966d0a1f1.jpg	187	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:20:47.990004+00	2026-02-16 19:22:59.615373+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	28347682-48f2-4ba0-a113-fa1edbd4f722	f
a34ed4d8-46fc-47f8-8437-a3bfc394467c	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: 99659b1a7ebf949dfb18d916025c6118]\n\n[task_id: 99659b1a7ebf949dfb18d916025c6118]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/a34ed4d8-46fc-47f8-8437-a3bfc394467c.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/a34ed4d8-46fc-47f8-8437-a3bfc394467c.jpg	174	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:27:40.512613+00	2026-02-16 19:29:42.650128+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	a5b12b28-a6c6-401f-aa14-89de31ed0043	f
756f24ca-6559-4339-a6c8-5e31e046c539	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v2)	Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, powerful female belts, diva solo vocals, powerhouse delivery, wide vocal range, gospel-inspired\n\n[task_id: df9f43cc420795d6fe1a2673b6dd6967]\n\n[task_id: df9f43cc420795d6fe1a2673b6dd6967]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/756f24ca-6559-4339-a6c8-5e31e046c539.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/756f24ca-6559-4339-a6c8-5e31e046c539-suno-1.png	211	\N	\N	\N	\N	\N	f	1	0	completed	2026-02-16 19:25:51.812718+00	2026-02-16 19:29:58.106364+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	1c4c18e8-1b8c-4878-b14f-2339a32f783f	f
d58f61e0-bcbf-4ca5-b177-2728af21fbca	fe67116b-0ad9-4491-9670-f40d1939db1e	Архив забытых снов (v1)	female vocal, Slap house, 124 BPM, aggressive bouncy deep bass, punchy drums, catchy vocal chops, high energy radio hit, crisp percussion, punchy low-end, professional mixing, indie, alternative style, raw and emotive, unique phrasing\n\n[task_id: 2c527b169abb8b4903bb63ee04698afa]\n\n[task_id: 2c527b169abb8b4903bb63ee04698afa]	В лабиринтах полутьмЫ и янтарЯ\nСобираю осколки снов заветных\nКаждый сон - как лист календаря\nКак песня нами не допетая\nЯ картОграф своих забытых снов\nЯ по ним свою жизнь читаю\nЧто сбылось, а что не сбылось\nПо забытым снам понять пытаюсь\n\nПрипев:\nЗабытые сны. Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nЯ думала, сны те ушли навсегда\nИ о себе никогда не напомнят\nЗабытые сны помнят что и когда\nИ что не сбылось, никто не исполнит\nНо есть один сон, его не забыть мне\nОн сбылся, оставив, мне память и боль\nКогда ты сказал, что было - забыто\nТот сон не забыла, во сне ты ушёл\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\nПрипев:\nЗабытые сны . Значит что-то забыто\nИ что не сбылось архивами скрыто\nА может те сны мне уже не нужны\nВсё-таки это забытые сны\n\n\n	https://aimuza.ru/storage/v1/object/public/tracks/audio/d58f61e0-bcbf-4ca5-b177-2728af21fbca.mp3	https://aimuza.ru/storage/v1/object/public/tracks/covers/d58f61e0-bcbf-4ca5-b177-2728af21fbca.jpg	\N	\N	\N	\N	\N	\N	f	0	0	completed	2026-02-16 19:33:25.858025+00	2026-02-16 19:35:06.406265+00	none	generated	\N	\N	\N	0	0	\N	\N	\N	\N	\N	\N	\N	\N	f	\N	0	0	\N	none	\N	\N	none	\N	t	f	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	0	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	f	f	\N	f	\N	\N	f	\N	\N	0	\N	\N	9096ec01-61d7-417b-bfa9-2b4d4f186ab6	f
\.


--
-- Data for Name: user_achievements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_achievements (id, user_id, achievement_id, unlocked_at) FROM stdin;
ac06b01d-bc47-414f-9fb8-d076ab3c8363	955ff6c1-f3db-4087-8e68-cb67ffc41862	ee1c37d0-eeb4-4159-a738-99719e3ac63c	2026-02-16 01:32:33.058835+00
b3be0fe9-61f9-45f3-95dc-02eb85e1806e	a0000000-0000-0000-0000-000000000001	ee1c37d0-eeb4-4159-a738-99719e3ac63c	2026-02-16 01:33:44.8428+00
\.


--
-- Data for Name: user_blocks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_blocks (id, user_id, blocked_by, reason, expires_at, created_at) FROM stdin;
\.


--
-- Data for Name: user_challenges; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_challenges (id, user_id, challenge_id, progress, completed, completed_at, created_at) FROM stdin;
\.


--
-- Data for Name: user_follows; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_follows (id, follower_id, following_id, created_at) FROM stdin;
\.


--
-- Data for Name: user_prompts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_prompts (id, user_id, title, description, prompt_text, genre, tags, price, is_public, downloads_count, rating, created_at, updated_at, lyrics, genre_id, vocal_type_id, template_id, artist_style_id, uses_count, track_id, is_exclusive, license_type) FROM stdin;
562cabd3-cc9f-4ca8-a3a6-53f32a83cebd	955ff6c1-f3db-4087-8e68-cb67ffc41862	Черновик 1	deep house, fast tempo		\N	\N	0	f	0	0	2026-02-14 20:56:05.291057+00	2026-02-14 20:56:05.291057+00	В полях ромашек, в шуме берёз,\nГде утро дарит розовый рос,\nЯ встретил взгляд — и в сердце весна,\nТы словно Русь, чиста и ясна.\n\n\nЛюбовь моя, ты — свет в моей судьбе,\nКак реки русские, текут к мечте.\nРоссия — дом, где мы с тобой вдвоём,\nЗдесь каждый миг наполнен волшебством.\n\n\nВ твоих глазах — озёра глубь,\nВ улыбке — солнца тёплый луч.\nМы вместе, как Москва и Нева,\nКак песня, что звучит всегда.\n\n\nЛюбовь моя, ты — свет в моей судьбе,\nКак реки русские, текут к мечте.\nРоссия — дом, где мы с тобой вдвоём,\nЗдесь каждый миг наполнен волшебством.\n\n\nПусть годы мчатся, как ветра,\nНо наша нежность — навсегда.\nВ объятиях Родины родной\nМы с тобой — одна семья.\n\n\nЛюбовь моя, ты — свет в моей судьбе,\nКак реки русские, текут к мечте.\nРоссия — дом, где мы с тобой вдвоём,\nЗдесь каждый миг наполнен волшебством!\n\n\nВ полях ромашек, в шуме берёз…\nТы — моя Русь, ты — мой вопрос.	\N	\N	\N	\N	0	\N	f	\N
\.


--
-- Data for Name: user_roles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_roles (id, user_id, role, created_at) FROM stdin;
92dd5997-8f01-44ae-9cb9-1d987d4eec53	a0000000-0000-0000-0000-000000000001	super_admin	2026-02-13 12:06:38.855563+00
90e2818b-957c-41dd-8c07-a5a077190c91	fe67116b-0ad9-4491-9670-f40d1939db1e	admin	2026-02-15 18:01:04.090374+00
f2ee5112-5833-4f79-94f3-b5f95167249b	577de5d6-c06e-4583-9631-9817db23b84d	admin	2026-02-15 22:02:16.005847+00
\.


--
-- Data for Name: user_streaks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_streaks (id, user_id, current_streak, longest_streak, last_activity_date, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: user_subscriptions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_subscriptions (id, user_id, plan_id, status, period_type, current_period_start, current_period_end, canceled_at, payment_id, created_at, updated_at) FROM stdin;
f2815e08-41ca-463b-9d8a-c47838a3dee5	a0000000-0000-0000-0000-000000000001	d604318a-660b-484c-a2fd-32963bcfd62a	active	monthly	2026-02-14 20:02:21.620255+00	2026-03-14 20:02:22.155+00	\N	\N	2026-02-14 20:02:21.620255+00	2026-02-14 20:02:21.620255+00
9fa3c51a-4ebc-4601-9cc5-62551b7b7c27	fe67116b-0ad9-4491-9670-f40d1939db1e	f3e6bbfc-6839-45f6-9aeb-7e9a3eec3839	active	monthly	2026-02-15 20:14:07.485448+00	2026-03-15 20:14:36.234+00	\N	\N	2026-02-15 20:14:07.485448+00	2026-02-15 20:14:07.485448+00
4f22ec1c-4b74-4929-8d6f-7e4c43c5dae1	fe67116b-0ad9-4491-9670-f40d1939db1e	3249ee6b-d760-48e1-b3a2-6733a04dd07d	active	monthly	2026-02-15 20:14:24.169422+00	2026-03-15 20:14:52.919+00	\N	\N	2026-02-15 20:14:24.169422+00	2026-02-15 20:14:24.169422+00
01092ad8-266f-4b60-93b3-b450558204a2	577de5d6-c06e-4583-9631-9817db23b84d	f3e6bbfc-6839-45f6-9aeb-7e9a3eec3839	active	monthly	2026-02-15 22:37:01.438379+00	2026-03-15 22:37:02.682+00	\N	\N	2026-02-15 22:37:01.438379+00	2026-02-15 22:37:01.438379+00
196c44c9-6811-40e5-aaaa-132ddab0db7b	955ff6c1-f3db-4087-8e68-cb67ffc41862	d604318a-660b-484c-a2fd-32963bcfd62a	active	monthly	2026-02-16 01:04:05.183659+00	2026-03-16 01:04:07.332+00	\N	\N	2026-02-16 01:04:05.183659+00	2026-02-16 01:04:05.183659+00
\.


--
-- Data for Name: verification_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.verification_requests (id, user_id, type, status, real_name, social_links, documents, notes, reviewed_by, reviewed_at, created_at, updated_at, rejection_reason) FROM stdin;
f9c120e9-5d8f-4305-9eb0-85617f1ed424	955ff6c1-f3db-4087-8e68-cb67ffc41862	artist	approved	\N	[{"url": "https://фывафывафыва", "platform": "vk"}]	[]	ываыфвафывафыва	a0000000-0000-0000-0000-000000000001	2026-02-15 19:04:28.337415+00	2026-02-15 18:56:54.832292+00	2026-02-15 18:56:54.832292+00	\N
bafe69f4-8816-407d-805b-6fb9f8298d13	fe67116b-0ad9-4491-9670-f40d1939db1e	artist	approved	Золотинка	[{"url": "https://vk.com/pevitcazolotinka", "platform": "vk"}]	[]	Автор-исполнитель	a0000000-0000-0000-0000-000000000001	2026-02-15 19:10:53.221987+00	2026-02-15 19:09:13.491698+00	2026-02-15 19:09:13.491698+00	\N
2254eb27-c463-44b6-9e71-f7cdf61d8ea4	577de5d6-c06e-4583-9631-9817db23b84d	partner	approved	Павел	[{"url": "https://vk.com/shvedov.pavell?z=photo508229006_457241375%2Fwall508229006_53", "platform": "vk"}]	[]	\N	a0000000-0000-0000-0000-000000000001	2026-02-15 23:21:15.127856+00	2026-02-15 23:15:41.230829+00	2026-02-15 23:15:41.230829+00	\N
\.


--
-- Data for Name: vocal_types; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.vocal_types (id, name, name_ru, description, is_active, sort_order, created_at) FROM stdin;
d16a126a-67f8-499d-91f8-1b862ad8abc8	male	Мужской	Мужской голос	t	1	2026-02-13 11:52:25.389321+00
52e8cc14-4905-47f4-8d2f-6d1caec54c1b	female	Женский	Женский голос	t	2	2026-02-13 11:52:25.389321+00
7e56b499-3159-4b40-b8a1-69585868e1a6	duet	Дуэт	Мужской и женский голос	t	3	2026-02-13 11:52:25.389321+00
a0fd9ed8-7277-4c5f-a662-f80e4a617822	instrumental	Инструментал	Без вокала	t	4	2026-02-13 11:52:25.389321+00
\.


--
-- Data for Name: xp_event_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.xp_event_config (id, event_type, xp_amount, reputation_amount, category, cooldown_minutes, daily_limit, requires_quality_check, description, is_active) FROM stdin;
5b39046b-f130-4e80-a93d-8e7b71e51e38	forum_post_created	3	1	forum	2	30	f	Создание поста на форуме	t
65491c10-fb7b-4059-b3ca-c16ff0cd5149	forum_topic_created	8	3	forum	5	10	f	Создание темы на форуме	t
ff9a8f05-48e1-4a8b-a421-77bcc1cd3ff8	forum_post_liked	2	1	forum	0	50	f	Получение лайка на пост	t
7d0cbabb-a00f-40c4-9ce0-a1fed04f195f	forum_solution_marked	15	5	forum	0	0	f	Пост отмечен как решение	t
403fae52-827a-4c0f-b2bd-26f8431c6209	track_published	5	2	music	0	20	f	Публикация трека	t
f717e6e9-460d-4463-acb7-be1161473e80	track_liked	2	1	music	0	100	f	Получение лайка на трек	t
e7979958-3edd-43af-9ac5-5414b2b16242	track_played_10	1	0	music	0	50	f	Прослушивание трека 10 раз	t
c008cf2f-da83-408c-a994-b864b161a034	track_shared	3	1	music	0	20	f	Поделились треком	t
2e042416-7de7-4330-97a6-02df8b6b22db	cover_uploaded	5	2	music	0	10	f	Загрузка обложки	t
62fe57fd-0a47-4e9b-9f25-c6e8e3a06371	follower_gained	3	1	social	0	0	f	Получение подписчика	t
36f2b563-81e0-49d4-bdc4-7d60e0b0ccdf	comment_posted	1	0	social	1	30	f	Написание комментария	t
bc606101-596b-4b53-8f2a-ace3610b0da2	collab_completed	20	8	social	0	5	t	Завершение коллаборации	t
6614222e-1be9-4ba8-8189-9f5e511af488	contest_entered	10	3	contest	0	5	f	Участие в конкурсе	t
ecdf8616-e954-4434-ae50-6690c6bca493	contest_won	50	20	contest	0	0	f	Победа в конкурсе	t
2c2c1e7e-7f03-4b43-b934-5661d5015d01	contest_top3	25	10	contest	0	0	f	Топ-3 в конкурсе	t
2a6f5946-389f-467e-94d1-15d1d8d11092	contest_voted	1	0	contest	1	30	f	Голосование в конкурсе	t
4548befc-fe34-40d3-8e3f-e8c9253288ba	daily_login	2	0	general	0	1	f	Ежедневный вход	t
3c20469e-7454-40f8-9e7f-223eef1b8b7d	profile_completed	10	5	general	0	1	f	Заполнение профиля	t
8bd71fc0-40c1-4148-9b5f-70294c7e7f1f	streak_milestone	20	5	general	0	0	f	Достижение стрика	t
4e6669bd-2436-4c4e-8ca6-0e877110b1fa	forum_guide_published	25	10	creator	0	5	t	Публикация гайда/туториала	t
2f969328-91a1-4788-a976-383ae134d46c	qa_report_resolved	15	5	general	0	20	f	???????????????????????????? ??????-????????????	t
0d6e32bc-00df-427c-aba7-f8ba3d47cb9f	radio_listen	1	0	music	0	50	f	?????????????????????????? ?????????? ???? ??????????	t
ffede59d-863b-4212-9ec1-96482b07971f	prediction_correct	10	3	general	0	20	f	???????????? ?????????????? ???? ??????????	t
1d465bf3-704d-48d3-ad8f-6121bbfd9a4e	prediction_wrong	1	0	general	0	50	f	???????????????? ?????????????? ???? ?????????? (????????????????????????)	t
11a77cc3-65c3-45c4-b1e3-48d5c7bf644c	qa_bounty_resolved	50	15	general	0	5	f	???????????????? ???????????? ???? ?????????????????? ????????????	t
590854ef-cb9d-4896-b67a-738a49c47628	track_rejected	0	-5	music	0	0	f	???????? ???????????????? ???????????????????? (??????????)	t
\.


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: achievements achievements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.achievements
    ADD CONSTRAINT achievements_pkey PRIMARY KEY (id);


--
-- Name: ad_campaign_slots ad_campaign_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_slots
    ADD CONSTRAINT ad_campaign_slots_pkey PRIMARY KEY (id);


--
-- Name: ad_campaigns ad_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaigns
    ADD CONSTRAINT ad_campaigns_pkey PRIMARY KEY (id);


--
-- Name: ad_creatives ad_creatives_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_creatives
    ADD CONSTRAINT ad_creatives_pkey PRIMARY KEY (id);


--
-- Name: ad_impressions ad_impressions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_pkey PRIMARY KEY (id);


--
-- Name: ad_settings ad_settings_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_settings
    ADD CONSTRAINT ad_settings_key_key UNIQUE (key);


--
-- Name: ad_settings ad_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_settings
    ADD CONSTRAINT ad_settings_pkey PRIMARY KEY (id);


--
-- Name: ad_slots ad_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_slots
    ADD CONSTRAINT ad_slots_pkey PRIMARY KEY (id);


--
-- Name: ad_targeting ad_targeting_campaign_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_targeting
    ADD CONSTRAINT ad_targeting_campaign_id_key UNIQUE (campaign_id);


--
-- Name: ad_targeting ad_targeting_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_targeting
    ADD CONSTRAINT ad_targeting_pkey PRIMARY KEY (id);


--
-- Name: addon_services addon_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addon_services
    ADD CONSTRAINT addon_services_pkey PRIMARY KEY (id);


--
-- Name: admin_announcements admin_announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_announcements
    ADD CONSTRAINT admin_announcements_pkey PRIMARY KEY (id);


--
-- Name: admin_emails admin_emails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_emails
    ADD CONSTRAINT admin_emails_pkey PRIMARY KEY (id);


--
-- Name: ai_models ai_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT ai_models_pkey PRIMARY KEY (id);


--
-- Name: ai_provider_settings ai_provider_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_settings
    ADD CONSTRAINT ai_provider_settings_pkey PRIMARY KEY (id);


--
-- Name: announcement_dismissals announcement_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_pkey PRIMARY KEY (id);


--
-- Name: announcements announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: artist_styles artist_styles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artist_styles
    ADD CONSTRAINT artist_styles_pkey PRIMARY KEY (id);


--
-- Name: attribution_pools attribution_pools_period_start_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_pools
    ADD CONSTRAINT attribution_pools_period_start_key UNIQUE (period_start);


--
-- Name: attribution_pools attribution_pools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_pools
    ADD CONSTRAINT attribution_pools_pkey PRIMARY KEY (id);


--
-- Name: attribution_shares attribution_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_shares
    ADD CONSTRAINT attribution_shares_pkey PRIMARY KEY (id);


--
-- Name: attribution_shares attribution_shares_pool_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_shares
    ADD CONSTRAINT attribution_shares_pool_id_user_id_key UNIQUE (pool_id, user_id);


--
-- Name: audio_separations audio_separations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audio_separations
    ADD CONSTRAINT audio_separations_pkey PRIMARY KEY (id);


--
-- Name: balance_transactions balance_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.balance_transactions
    ADD CONSTRAINT balance_transactions_pkey PRIMARY KEY (id);


--
-- Name: beat_purchases beat_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beat_purchases
    ADD CONSTRAINT beat_purchases_pkey PRIMARY KEY (id);


--
-- Name: bug_reports bug_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bug_reports
    ADD CONSTRAINT bug_reports_pkey PRIMARY KEY (id);


--
-- Name: challenges challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.challenges
    ADD CONSTRAINT challenges_pkey PRIMARY KEY (id);


--
-- Name: comment_likes comment_likes_comment_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_comment_id_user_id_key UNIQUE (comment_id, user_id);


--
-- Name: comment_likes comment_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_pkey PRIMARY KEY (id);


--
-- Name: comment_mentions comment_mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_mentions
    ADD CONSTRAINT comment_mentions_pkey PRIMARY KEY (id);


--
-- Name: comment_reactions comment_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_reactions
    ADD CONSTRAINT comment_reactions_pkey PRIMARY KEY (id);


--
-- Name: comment_reports comment_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_reports
    ADD CONSTRAINT comment_reports_pkey PRIMARY KEY (id);


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (id);


--
-- Name: contest_achievements contest_achievements_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_achievements
    ADD CONSTRAINT contest_achievements_key_key UNIQUE (key);


--
-- Name: contest_achievements contest_achievements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_achievements
    ADD CONSTRAINT contest_achievements_pkey PRIMARY KEY (id);


--
-- Name: contest_asset_downloads contest_asset_downloads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_asset_downloads
    ADD CONSTRAINT contest_asset_downloads_pkey PRIMARY KEY (id);


--
-- Name: contest_comment_likes contest_comment_likes_comment_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_comment_likes
    ADD CONSTRAINT contest_comment_likes_comment_id_user_id_key UNIQUE (comment_id, user_id);


--
-- Name: contest_comment_likes contest_comment_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_comment_likes
    ADD CONSTRAINT contest_comment_likes_pkey PRIMARY KEY (id);


--
-- Name: contest_entries contest_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entries
    ADD CONSTRAINT contest_entries_pkey PRIMARY KEY (id);


--
-- Name: contest_entry_comments contest_entry_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entry_comments
    ADD CONSTRAINT contest_entry_comments_pkey PRIMARY KEY (id);


--
-- Name: contest_jury contest_jury_contest_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_jury
    ADD CONSTRAINT contest_jury_contest_id_user_id_key UNIQUE (contest_id, user_id);


--
-- Name: contest_jury contest_jury_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_jury
    ADD CONSTRAINT contest_jury_pkey PRIMARY KEY (id);


--
-- Name: contest_jury_scores contest_jury_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_jury_scores
    ADD CONSTRAINT contest_jury_scores_pkey PRIMARY KEY (id);


--
-- Name: contest_leagues contest_leagues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_leagues
    ADD CONSTRAINT contest_leagues_pkey PRIMARY KEY (id);


--
-- Name: contest_leagues contest_leagues_tier_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_leagues
    ADD CONSTRAINT contest_leagues_tier_key UNIQUE (tier);


--
-- Name: contest_ratings contest_ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_ratings
    ADD CONSTRAINT contest_ratings_pkey PRIMARY KEY (id);


--
-- Name: contest_ratings contest_ratings_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_ratings
    ADD CONSTRAINT contest_ratings_user_id_key UNIQUE (user_id);


--
-- Name: contest_seasons contest_seasons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_seasons
    ADD CONSTRAINT contest_seasons_pkey PRIMARY KEY (id);


--
-- Name: contest_user_achievements contest_user_achievements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_user_achievements
    ADD CONSTRAINT contest_user_achievements_pkey PRIMARY KEY (id);


--
-- Name: contest_user_achievements contest_user_achievements_user_id_achievement_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_user_achievements
    ADD CONSTRAINT contest_user_achievements_user_id_achievement_id_key UNIQUE (user_id, achievement_id);


--
-- Name: contest_votes contest_votes_entry_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_votes
    ADD CONSTRAINT contest_votes_entry_id_user_id_key UNIQUE (entry_id, user_id);


--
-- Name: contest_votes contest_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_votes
    ADD CONSTRAINT contest_votes_pkey PRIMARY KEY (id);


--
-- Name: contest_winners contest_winners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_winners
    ADD CONSTRAINT contest_winners_pkey PRIMARY KEY (id);


--
-- Name: contests contests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contests
    ADD CONSTRAINT contests_pkey PRIMARY KEY (id);


--
-- Name: conversation_participants conversation_participants_conversation_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants
    ADD CONSTRAINT conversation_participants_conversation_id_user_id_key UNIQUE (conversation_id, user_id);


--
-- Name: conversation_participants conversation_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants
    ADD CONSTRAINT conversation_participants_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: copyright_requests copyright_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copyright_requests
    ADD CONSTRAINT copyright_requests_pkey PRIMARY KEY (id);


--
-- Name: creator_earnings creator_earnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_earnings
    ADD CONSTRAINT creator_earnings_pkey PRIMARY KEY (id);


--
-- Name: creator_earnings creator_earnings_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_earnings
    ADD CONSTRAINT creator_earnings_user_id_key UNIQUE (user_id);


--
-- Name: distribution_logs distribution_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_logs
    ADD CONSTRAINT distribution_logs_pkey PRIMARY KEY (id);


--
-- Name: distribution_requests distribution_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_requests
    ADD CONSTRAINT distribution_requests_pkey PRIMARY KEY (id);


--
-- Name: economy_config economy_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_config
    ADD CONSTRAINT economy_config_pkey PRIMARY KEY (key);


--
-- Name: economy_snapshots economy_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_snapshots
    ADD CONSTRAINT economy_snapshots_pkey PRIMARY KEY (id);


--
-- Name: economy_snapshots economy_snapshots_snapshot_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_snapshots
    ADD CONSTRAINT economy_snapshots_snapshot_date_key UNIQUE (snapshot_date);


--
-- Name: email_templates email_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_pkey PRIMARY KEY (id);


--
-- Name: email_templates email_templates_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_slug_key UNIQUE (slug);


--
-- Name: email_verifications email_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_pkey PRIMARY KEY (id);


--
-- Name: error_logs error_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_logs
    ADD CONSTRAINT error_logs_pkey PRIMARY KEY (id);


--
-- Name: feature_trials feature_trials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_trials
    ADD CONSTRAINT feature_trials_pkey PRIMARY KEY (id);


--
-- Name: feed_config feed_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_config
    ADD CONSTRAINT feed_config_pkey PRIMARY KEY (key);


--
-- Name: follows follows_follower_id_following_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_follower_id_following_id_key UNIQUE (follower_id, following_id);


--
-- Name: follows follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_pkey PRIMARY KEY (id);


--
-- Name: forum_activity_log forum_activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_activity_log
    ADD CONSTRAINT forum_activity_log_pkey PRIMARY KEY (id);


--
-- Name: forum_attachments forum_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_attachments
    ADD CONSTRAINT forum_attachments_pkey PRIMARY KEY (id);


--
-- Name: forum_automod_settings forum_automod_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_automod_settings
    ADD CONSTRAINT forum_automod_settings_pkey PRIMARY KEY (id);


--
-- Name: forum_bookmarks forum_bookmarks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_bookmarks
    ADD CONSTRAINT forum_bookmarks_pkey PRIMARY KEY (id);


--
-- Name: forum_bookmarks forum_bookmarks_user_id_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_bookmarks
    ADD CONSTRAINT forum_bookmarks_user_id_topic_id_key UNIQUE (user_id, topic_id);


--
-- Name: forum_categories forum_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_categories
    ADD CONSTRAINT forum_categories_pkey PRIMARY KEY (id);


--
-- Name: forum_categories forum_categories_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_categories
    ADD CONSTRAINT forum_categories_slug_key UNIQUE (slug);


--
-- Name: forum_category_subscriptions forum_category_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_category_subscriptions
    ADD CONSTRAINT forum_category_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: forum_category_subscriptions forum_category_subscriptions_user_id_category_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_category_subscriptions
    ADD CONSTRAINT forum_category_subscriptions_user_id_category_id_key UNIQUE (user_id, category_id);


--
-- Name: forum_citations forum_citations_article_id_citing_post_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_article_id_citing_post_id_key UNIQUE (article_id, citing_post_id);


--
-- Name: forum_citations forum_citations_article_id_citing_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_article_id_citing_topic_id_key UNIQUE (article_id, citing_topic_id);


--
-- Name: forum_citations forum_citations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_pkey PRIMARY KEY (id);


--
-- Name: forum_content_purchases forum_content_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_content_purchases
    ADD CONSTRAINT forum_content_purchases_pkey PRIMARY KEY (id);


--
-- Name: forum_content_purchases forum_content_purchases_topic_id_buyer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_content_purchases
    ADD CONSTRAINT forum_content_purchases_topic_id_buyer_id_key UNIQUE (topic_id, buyer_id);


--
-- Name: forum_content_quality forum_content_quality_content_type_content_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_content_quality
    ADD CONSTRAINT forum_content_quality_content_type_content_id_key UNIQUE (content_type, content_id);


--
-- Name: forum_content_quality forum_content_quality_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_content_quality
    ADD CONSTRAINT forum_content_quality_pkey PRIMARY KEY (id);


--
-- Name: forum_drafts forum_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_drafts
    ADD CONSTRAINT forum_drafts_pkey PRIMARY KEY (id);


--
-- Name: forum_hub_config forum_hub_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_hub_config
    ADD CONSTRAINT forum_hub_config_pkey PRIMARY KEY (key);


--
-- Name: forum_knowledge_articles forum_knowledge_articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_knowledge_articles
    ADD CONSTRAINT forum_knowledge_articles_pkey PRIMARY KEY (id);


--
-- Name: forum_link_previews forum_link_previews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_link_previews
    ADD CONSTRAINT forum_link_previews_pkey PRIMARY KEY (id);


--
-- Name: forum_link_previews forum_link_previews_url_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_link_previews
    ADD CONSTRAINT forum_link_previews_url_key UNIQUE (url);


--
-- Name: forum_mod_logs forum_mod_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_mod_logs
    ADD CONSTRAINT forum_mod_logs_pkey PRIMARY KEY (id);


--
-- Name: forum_poll_options forum_poll_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_options
    ADD CONSTRAINT forum_poll_options_pkey PRIMARY KEY (id);


--
-- Name: forum_poll_votes forum_poll_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_votes
    ADD CONSTRAINT forum_poll_votes_pkey PRIMARY KEY (id);


--
-- Name: forum_poll_votes forum_poll_votes_poll_id_option_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_votes
    ADD CONSTRAINT forum_poll_votes_poll_id_option_id_user_id_key UNIQUE (poll_id, option_id, user_id);


--
-- Name: forum_polls forum_polls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_polls
    ADD CONSTRAINT forum_polls_pkey PRIMARY KEY (id);


--
-- Name: forum_post_reactions forum_post_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_reactions
    ADD CONSTRAINT forum_post_reactions_pkey PRIMARY KEY (id);


--
-- Name: forum_post_reactions forum_post_reactions_post_id_user_id_emoji_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_reactions
    ADD CONSTRAINT forum_post_reactions_post_id_user_id_emoji_key UNIQUE (post_id, user_id, emoji);


--
-- Name: forum_post_votes forum_post_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_votes
    ADD CONSTRAINT forum_post_votes_pkey PRIMARY KEY (id);


--
-- Name: forum_post_votes forum_post_votes_post_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_votes
    ADD CONSTRAINT forum_post_votes_post_id_user_id_key UNIQUE (post_id, user_id);


--
-- Name: forum_posts forum_posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_posts
    ADD CONSTRAINT forum_posts_pkey PRIMARY KEY (id);


--
-- Name: forum_premium_content forum_premium_content_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_premium_content
    ADD CONSTRAINT forum_premium_content_pkey PRIMARY KEY (id);


--
-- Name: forum_promo_slots forum_promo_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_promo_slots
    ADD CONSTRAINT forum_promo_slots_pkey PRIMARY KEY (id);


--
-- Name: forum_read_status forum_read_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_read_status
    ADD CONSTRAINT forum_read_status_pkey PRIMARY KEY (id);


--
-- Name: forum_read_status forum_read_status_user_id_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_read_status
    ADD CONSTRAINT forum_read_status_user_id_topic_id_key UNIQUE (user_id, topic_id);


--
-- Name: forum_reports forum_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_reports
    ADD CONSTRAINT forum_reports_pkey PRIMARY KEY (id);


--
-- Name: forum_reputation_config forum_reputation_config_action_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_reputation_config
    ADD CONSTRAINT forum_reputation_config_action_key UNIQUE (action);


--
-- Name: forum_reputation_config forum_reputation_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_reputation_config
    ADD CONSTRAINT forum_reputation_config_pkey PRIMARY KEY (id);


--
-- Name: forum_reputation_log forum_reputation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_reputation_log
    ADD CONSTRAINT forum_reputation_log_pkey PRIMARY KEY (id);


--
-- Name: forum_similar_topics forum_similar_topics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_similar_topics
    ADD CONSTRAINT forum_similar_topics_pkey PRIMARY KEY (id);


--
-- Name: forum_similar_topics forum_similar_topics_topic_a_id_topic_b_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_similar_topics
    ADD CONSTRAINT forum_similar_topics_topic_a_id_topic_b_id_key UNIQUE (topic_a_id, topic_b_id);


--
-- Name: forum_staff_notes forum_staff_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_staff_notes
    ADD CONSTRAINT forum_staff_notes_pkey PRIMARY KEY (id);


--
-- Name: forum_tags forum_tags_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_tags
    ADD CONSTRAINT forum_tags_name_key UNIQUE (name);


--
-- Name: forum_tags forum_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_tags
    ADD CONSTRAINT forum_tags_pkey PRIMARY KEY (id);


--
-- Name: forum_tags forum_tags_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_tags
    ADD CONSTRAINT forum_tags_slug_key UNIQUE (slug);


--
-- Name: forum_topic_boosts forum_topic_boosts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_boosts
    ADD CONSTRAINT forum_topic_boosts_pkey PRIMARY KEY (id);


--
-- Name: forum_topic_cluster_members forum_topic_cluster_members_cluster_id_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_cluster_members
    ADD CONSTRAINT forum_topic_cluster_members_cluster_id_topic_id_key UNIQUE (cluster_id, topic_id);


--
-- Name: forum_topic_cluster_members forum_topic_cluster_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_cluster_members
    ADD CONSTRAINT forum_topic_cluster_members_pkey PRIMARY KEY (id);


--
-- Name: forum_topic_clusters forum_topic_clusters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_clusters
    ADD CONSTRAINT forum_topic_clusters_pkey PRIMARY KEY (id);


--
-- Name: forum_topic_subscriptions forum_topic_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_subscriptions
    ADD CONSTRAINT forum_topic_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: forum_topic_subscriptions forum_topic_subscriptions_user_id_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_subscriptions
    ADD CONSTRAINT forum_topic_subscriptions_user_id_topic_id_key UNIQUE (user_id, topic_id);


--
-- Name: forum_topic_tags forum_topic_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_tags
    ADD CONSTRAINT forum_topic_tags_pkey PRIMARY KEY (id);


--
-- Name: forum_topic_tags forum_topic_tags_topic_id_tag_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_tags
    ADD CONSTRAINT forum_topic_tags_topic_id_tag_id_key UNIQUE (topic_id, tag_id);


--
-- Name: forum_topics forum_topics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topics
    ADD CONSTRAINT forum_topics_pkey PRIMARY KEY (id);


--
-- Name: forum_user_bans forum_user_bans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_bans
    ADD CONSTRAINT forum_user_bans_pkey PRIMARY KEY (id);


--
-- Name: forum_user_ignores forum_user_ignores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_ignores
    ADD CONSTRAINT forum_user_ignores_pkey PRIMARY KEY (id);


--
-- Name: forum_user_ignores forum_user_ignores_user_id_ignored_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_ignores
    ADD CONSTRAINT forum_user_ignores_user_id_ignored_user_id_key UNIQUE (user_id, ignored_user_id);


--
-- Name: forum_user_reads forum_user_reads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_reads
    ADD CONSTRAINT forum_user_reads_pkey PRIMARY KEY (id);


--
-- Name: forum_user_reads forum_user_reads_user_id_topic_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_reads
    ADD CONSTRAINT forum_user_reads_user_id_topic_id_key UNIQUE (user_id, topic_id);


--
-- Name: forum_user_stats forum_user_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_stats
    ADD CONSTRAINT forum_user_stats_pkey PRIMARY KEY (id);


--
-- Name: forum_user_stats forum_user_stats_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_user_stats
    ADD CONSTRAINT forum_user_stats_user_id_key UNIQUE (user_id);


--
-- Name: forum_warning_appeals forum_warning_appeals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_warning_appeals
    ADD CONSTRAINT forum_warning_appeals_pkey PRIMARY KEY (id);


--
-- Name: forum_warning_points forum_warning_points_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_warning_points
    ADD CONSTRAINT forum_warning_points_pkey PRIMARY KEY (id);


--
-- Name: forum_warnings forum_warnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_warnings
    ADD CONSTRAINT forum_warnings_pkey PRIMARY KEY (id);


--
-- Name: gallery_items gallery_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_items
    ADD CONSTRAINT gallery_items_pkey PRIMARY KEY (id);


--
-- Name: gallery_likes gallery_likes_gallery_item_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_likes
    ADD CONSTRAINT gallery_likes_gallery_item_id_user_id_key UNIQUE (gallery_item_id, user_id);


--
-- Name: gallery_likes gallery_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_likes
    ADD CONSTRAINT gallery_likes_pkey PRIMARY KEY (id);


--
-- Name: generated_lyrics generated_lyrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generated_lyrics
    ADD CONSTRAINT generated_lyrics_pkey PRIMARY KEY (id);


--
-- Name: generation_logs generation_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_logs
    ADD CONSTRAINT generation_logs_pkey PRIMARY KEY (id);


--
-- Name: generation_queue generation_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_queue
    ADD CONSTRAINT generation_queue_pkey PRIMARY KEY (id);


--
-- Name: genre_categories genre_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genre_categories
    ADD CONSTRAINT genre_categories_pkey PRIMARY KEY (id);


--
-- Name: genres genres_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genres
    ADD CONSTRAINT genres_pkey PRIMARY KEY (id);


--
-- Name: impersonation_action_logs impersonation_action_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.impersonation_action_logs
    ADD CONSTRAINT impersonation_action_logs_pkey PRIMARY KEY (id);


--
-- Name: internal_votes internal_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.internal_votes
    ADD CONSTRAINT internal_votes_pkey PRIMARY KEY (id);


--
-- Name: item_purchases item_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_purchases
    ADD CONSTRAINT item_purchases_pkey PRIMARY KEY (id);


--
-- Name: legal_documents legal_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT legal_documents_pkey PRIMARY KEY (id);


--
-- Name: lyrics_deposits lyrics_deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lyrics_deposits
    ADD CONSTRAINT lyrics_deposits_pkey PRIMARY KEY (id);


--
-- Name: lyrics_items lyrics_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lyrics_items
    ADD CONSTRAINT lyrics_items_pkey PRIMARY KEY (id);


--
-- Name: lyrics lyrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lyrics
    ADD CONSTRAINT lyrics_pkey PRIMARY KEY (id);


--
-- Name: maintenance_whitelist maintenance_whitelist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.maintenance_whitelist
    ADD CONSTRAINT maintenance_whitelist_pkey PRIMARY KEY (id);


--
-- Name: message_reactions message_reactions_message_id_user_id_emoji_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_message_id_user_id_emoji_key UNIQUE (message_id, user_id, emoji);


--
-- Name: message_reactions message_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: moderator_permissions moderator_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_permissions
    ADD CONSTRAINT moderator_permissions_pkey PRIMARY KEY (id);


--
-- Name: moderator_presets moderator_presets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_presets
    ADD CONSTRAINT moderator_presets_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: payout_requests payout_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_requests
    ADD CONSTRAINT payout_requests_pkey PRIMARY KEY (id);


--
-- Name: performance_alerts performance_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_alerts
    ADD CONSTRAINT performance_alerts_pkey PRIMARY KEY (id);


--
-- Name: permission_categories permission_categories_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_categories
    ADD CONSTRAINT permission_categories_key_key UNIQUE (key);


--
-- Name: permission_categories permission_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_categories
    ADD CONSTRAINT permission_categories_pkey PRIMARY KEY (id);


--
-- Name: permission_categories permission_categories_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_categories
    ADD CONSTRAINT permission_categories_slug_key UNIQUE (slug);


--
-- Name: personas personas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personas
    ADD CONSTRAINT personas_pkey PRIMARY KEY (id);


--
-- Name: playlist_tracks playlist_tracks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.playlist_tracks
    ADD CONSTRAINT playlist_tracks_pkey PRIMARY KEY (id);


--
-- Name: playlists playlists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.playlists
    ADD CONSTRAINT playlists_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_key UNIQUE (user_id);


--
-- Name: promo_videos promo_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.promo_videos
    ADD CONSTRAINT promo_videos_pkey PRIMARY KEY (id);


--
-- Name: prompt_purchases prompt_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_purchases
    ADD CONSTRAINT prompt_purchases_pkey PRIMARY KEY (id);


--
-- Name: prompts prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);


--
-- Name: qa_bounties qa_bounties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_bounties
    ADD CONSTRAINT qa_bounties_pkey PRIMARY KEY (id);


--
-- Name: qa_comments qa_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_comments
    ADD CONSTRAINT qa_comments_pkey PRIMARY KEY (id);


--
-- Name: qa_config qa_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_config
    ADD CONSTRAINT qa_config_pkey PRIMARY KEY (key);


--
-- Name: qa_tester_stats qa_tester_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_tester_stats
    ADD CONSTRAINT qa_tester_stats_pkey PRIMARY KEY (user_id);


--
-- Name: qa_tickets qa_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_tickets
    ADD CONSTRAINT qa_tickets_pkey PRIMARY KEY (id);


--
-- Name: qa_tickets qa_tickets_ticket_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_tickets
    ADD CONSTRAINT qa_tickets_ticket_number_key UNIQUE (ticket_number);


--
-- Name: qa_votes qa_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_votes
    ADD CONSTRAINT qa_votes_pkey PRIMARY KEY (id);


--
-- Name: qa_votes qa_votes_ticket_id_user_id_vote_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_votes
    ADD CONSTRAINT qa_votes_ticket_id_user_id_vote_type_key UNIQUE (ticket_id, user_id, vote_type);


--
-- Name: radio_ad_placements radio_ad_placements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_ad_placements
    ADD CONSTRAINT radio_ad_placements_pkey PRIMARY KEY (id);


--
-- Name: radio_bids radio_bids_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_bids
    ADD CONSTRAINT radio_bids_pkey PRIMARY KEY (id);


--
-- Name: radio_config radio_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_config
    ADD CONSTRAINT radio_config_pkey PRIMARY KEY (key);


--
-- Name: radio_listens radio_listens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listens
    ADD CONSTRAINT radio_listens_pkey PRIMARY KEY (id);


--
-- Name: radio_predictions radio_predictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_predictions
    ADD CONSTRAINT radio_predictions_pkey PRIMARY KEY (id);


--
-- Name: radio_queue radio_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_queue
    ADD CONSTRAINT radio_queue_pkey PRIMARY KEY (id);


--
-- Name: radio_slots radio_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_slots
    ADD CONSTRAINT radio_slots_pkey PRIMARY KEY (id);


--
-- Name: referral_codes referral_codes_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_codes
    ADD CONSTRAINT referral_codes_code_key UNIQUE (code);


--
-- Name: referral_codes referral_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_codes
    ADD CONSTRAINT referral_codes_pkey PRIMARY KEY (id);


--
-- Name: referral_rewards referral_rewards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_rewards
    ADD CONSTRAINT referral_rewards_pkey PRIMARY KEY (id);


--
-- Name: referral_settings referral_settings_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_settings
    ADD CONSTRAINT referral_settings_key_key UNIQUE (key);


--
-- Name: referral_settings referral_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_settings
    ADD CONSTRAINT referral_settings_pkey PRIMARY KEY (id);


--
-- Name: referral_stats referral_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_stats
    ADD CONSTRAINT referral_stats_pkey PRIMARY KEY (id);


--
-- Name: referral_stats referral_stats_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_stats
    ADD CONSTRAINT referral_stats_user_id_key UNIQUE (user_id);


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_pkey PRIMARY KEY (id);


--
-- Name: reputation_events reputation_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reputation_events
    ADD CONSTRAINT reputation_events_pkey PRIMARY KEY (id);


--
-- Name: reputation_tiers reputation_tiers_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reputation_tiers
    ADD CONSTRAINT reputation_tiers_key_key UNIQUE (key);


--
-- Name: reputation_tiers reputation_tiers_level_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reputation_tiers
    ADD CONSTRAINT reputation_tiers_level_key UNIQUE (level);


--
-- Name: reputation_tiers reputation_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reputation_tiers
    ADD CONSTRAINT reputation_tiers_pkey PRIMARY KEY (id);


--
-- Name: role_change_logs role_change_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_change_logs
    ADD CONSTRAINT role_change_logs_pkey PRIMARY KEY (id);


--
-- Name: role_invitation_permissions role_invitation_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_invitation_permissions
    ADD CONSTRAINT role_invitation_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_invitations role_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_invitations
    ADD CONSTRAINT role_invitations_pkey PRIMARY KEY (id);


--
-- Name: security_audit_log security_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_audit_log
    ADD CONSTRAINT security_audit_log_pkey PRIMARY KEY (id);


--
-- Name: seller_earnings seller_earnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_earnings
    ADD CONSTRAINT seller_earnings_pkey PRIMARY KEY (id);


--
-- Name: settings settings_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_key_key UNIQUE (key);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: store_beats store_beats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_beats
    ADD CONSTRAINT store_beats_pkey PRIMARY KEY (id);


--
-- Name: store_items store_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_items
    ADD CONSTRAINT store_items_pkey PRIMARY KEY (id);


--
-- Name: subscription_plans subscription_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_plans
    ADD CONSTRAINT subscription_plans_pkey PRIMARY KEY (id);


--
-- Name: support_messages support_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_messages
    ADD CONSTRAINT support_messages_pkey PRIMARY KEY (id);


--
-- Name: support_tickets support_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_pkey PRIMARY KEY (id);


--
-- Name: system_settings system_settings_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_key_key UNIQUE (key);


--
-- Name: system_settings system_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_pkey PRIMARY KEY (id);


--
-- Name: templates templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.templates
    ADD CONSTRAINT templates_pkey PRIMARY KEY (id);


--
-- Name: ticket_messages ticket_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticket_messages
    ADD CONSTRAINT ticket_messages_pkey PRIMARY KEY (id);


--
-- Name: track_addons track_addons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_addons
    ADD CONSTRAINT track_addons_pkey PRIMARY KEY (id);


--
-- Name: track_bookmarks track_bookmarks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_bookmarks
    ADD CONSTRAINT track_bookmarks_pkey PRIMARY KEY (id);


--
-- Name: track_bookmarks track_bookmarks_user_id_track_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_bookmarks
    ADD CONSTRAINT track_bookmarks_user_id_track_id_key UNIQUE (user_id, track_id);


--
-- Name: track_comments track_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_comments
    ADD CONSTRAINT track_comments_pkey PRIMARY KEY (id);


--
-- Name: track_daily_stats track_daily_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_daily_stats
    ADD CONSTRAINT track_daily_stats_pkey PRIMARY KEY (id);


--
-- Name: track_daily_stats track_daily_stats_track_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_daily_stats
    ADD CONSTRAINT track_daily_stats_track_id_date_key UNIQUE (track_id, date);


--
-- Name: track_deposits track_deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_deposits
    ADD CONSTRAINT track_deposits_pkey PRIMARY KEY (id);


--
-- Name: track_deposits track_deposits_track_id_method_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_deposits
    ADD CONSTRAINT track_deposits_track_id_method_key UNIQUE (track_id, method);


--
-- Name: track_feed_scores track_feed_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_feed_scores
    ADD CONSTRAINT track_feed_scores_pkey PRIMARY KEY (track_id);


--
-- Name: track_health_reports track_health_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_health_reports
    ADD CONSTRAINT track_health_reports_pkey PRIMARY KEY (id);


--
-- Name: track_likes track_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_likes
    ADD CONSTRAINT track_likes_pkey PRIMARY KEY (id);


--
-- Name: track_likes track_likes_user_id_track_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_likes
    ADD CONSTRAINT track_likes_user_id_track_id_key UNIQUE (user_id, track_id);


--
-- Name: track_promotions track_promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_promotions
    ADD CONSTRAINT track_promotions_pkey PRIMARY KEY (id);


--
-- Name: track_quality_scores track_quality_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_quality_scores
    ADD CONSTRAINT track_quality_scores_pkey PRIMARY KEY (id);


--
-- Name: track_quality_scores track_quality_scores_track_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_quality_scores
    ADD CONSTRAINT track_quality_scores_track_id_key UNIQUE (track_id);


--
-- Name: track_reactions track_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reactions
    ADD CONSTRAINT track_reactions_pkey PRIMARY KEY (id);


--
-- Name: track_reactions track_reactions_track_id_user_id_reaction_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reactions
    ADD CONSTRAINT track_reactions_track_id_user_id_reaction_type_key UNIQUE (track_id, user_id, reaction_type);


--
-- Name: track_reports track_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reports
    ADD CONSTRAINT track_reports_pkey PRIMARY KEY (id);


--
-- Name: track_votes track_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_votes
    ADD CONSTRAINT track_votes_pkey PRIMARY KEY (id);


--
-- Name: track_votes track_votes_track_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_votes
    ADD CONSTRAINT track_votes_track_id_user_id_key UNIQUE (track_id, user_id);


--
-- Name: tracks tracks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_pkey PRIMARY KEY (id);


--
-- Name: user_achievements user_achievements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_achievements
    ADD CONSTRAINT user_achievements_pkey PRIMARY KEY (id);


--
-- Name: user_achievements user_achievements_user_id_achievement_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_achievements
    ADD CONSTRAINT user_achievements_user_id_achievement_id_key UNIQUE (user_id, achievement_id);


--
-- Name: user_blocks user_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_pkey PRIMARY KEY (id);


--
-- Name: user_challenges user_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_challenges
    ADD CONSTRAINT user_challenges_pkey PRIMARY KEY (id);


--
-- Name: user_follows user_follows_follower_id_following_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_follows
    ADD CONSTRAINT user_follows_follower_id_following_id_key UNIQUE (follower_id, following_id);


--
-- Name: user_follows user_follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_follows
    ADD CONSTRAINT user_follows_pkey PRIMARY KEY (id);


--
-- Name: user_prompts user_prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_prompts
    ADD CONSTRAINT user_prompts_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_user_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_role_key UNIQUE (user_id, role);


--
-- Name: user_streaks user_streaks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_streaks
    ADD CONSTRAINT user_streaks_pkey PRIMARY KEY (id);


--
-- Name: user_streaks user_streaks_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_streaks
    ADD CONSTRAINT user_streaks_user_id_key UNIQUE (user_id);


--
-- Name: user_subscriptions user_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_subscriptions
    ADD CONSTRAINT user_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: verification_requests verification_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_requests
    ADD CONSTRAINT verification_requests_pkey PRIMARY KEY (id);


--
-- Name: vocal_types vocal_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vocal_types
    ADD CONSTRAINT vocal_types_pkey PRIMARY KEY (id);


--
-- Name: xp_event_config xp_event_config_event_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xp_event_config
    ADD CONSTRAINT xp_event_config_event_type_key UNIQUE (event_type);


--
-- Name: xp_event_config xp_event_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xp_event_config
    ADD CONSTRAINT xp_event_config_pkey PRIMARY KEY (id);


--
-- Name: idx_auth_users_email; Type: INDEX; Schema: auth; Owner: -
--

CREATE INDEX idx_auth_users_email ON auth.users USING btree (email);


--
-- Name: ad_slots_slot_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ad_slots_slot_key_idx ON public.ad_slots USING btree (slot_key);


--
-- Name: idx_achievements_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_achievements_key ON public.achievements USING btree (key);


--
-- Name: idx_ad_impressions_campaign_viewed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ad_impressions_campaign_viewed ON public.ad_impressions USING btree (campaign_id, viewed_at DESC);


--
-- Name: idx_ad_impressions_user_viewed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ad_impressions_user_viewed ON public.ad_impressions USING btree (user_id, viewed_at DESC);


--
-- Name: idx_attribution_shares_pool; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attribution_shares_pool ON public.attribution_shares USING btree (pool_id);


--
-- Name: idx_attribution_shares_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attribution_shares_user ON public.attribution_shares USING btree (user_id);


--
-- Name: idx_balance_tx_user_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_balance_tx_user_date ON public.balance_transactions USING btree (user_id, created_at DESC);


--
-- Name: idx_contest_ratings_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contest_ratings_rating ON public.contest_ratings USING btree (rating DESC);


--
-- Name: idx_contest_ratings_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contest_ratings_season ON public.contest_ratings USING btree (season_id, season_points DESC);


--
-- Name: idx_contest_ratings_weekly; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contest_ratings_weekly ON public.contest_ratings USING btree (weekly_points DESC);


--
-- Name: idx_contest_user_achievements_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contest_user_achievements_user ON public.contest_user_achievements USING btree (user_id);


--
-- Name: idx_conv_participants_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_conv_participants_user_id ON public.conversation_participants USING btree (user_id);


--
-- Name: idx_creator_earnings_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creator_earnings_user ON public.creator_earnings USING btree (user_id);


--
-- Name: idx_feed_scores_final; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feed_scores_final ON public.track_feed_scores USING btree (final_score DESC);


--
-- Name: idx_feed_scores_velocity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feed_scores_velocity ON public.track_feed_scores USING btree (velocity_24h DESC);


--
-- Name: idx_forum_boosts_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_boosts_active ON public.forum_topic_boosts USING btree (is_active, ends_at) WHERE is_active;


--
-- Name: idx_forum_boosts_topic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_boosts_topic ON public.forum_topic_boosts USING btree (topic_id);


--
-- Name: idx_forum_cq_author; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_cq_author ON public.forum_content_quality USING btree (author_id);


--
-- Name: idx_forum_cq_quality; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_cq_quality ON public.forum_content_quality USING btree (overall_quality DESC);


--
-- Name: idx_forum_kb_author; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_kb_author ON public.forum_knowledge_articles USING btree (author_id);


--
-- Name: idx_forum_kb_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_kb_category ON public.forum_knowledge_articles USING btree (category);


--
-- Name: idx_forum_kb_featured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_kb_featured ON public.forum_knowledge_articles USING btree (is_featured) WHERE is_featured;


--
-- Name: idx_forum_kb_quality; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_kb_quality ON public.forum_knowledge_articles USING btree (quality_score DESC);


--
-- Name: idx_forum_kb_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_kb_status ON public.forum_knowledge_articles USING btree (status);


--
-- Name: idx_forum_posts_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_posts_created_at ON public.forum_posts USING btree (created_at);


--
-- Name: idx_forum_posts_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_posts_parent_id ON public.forum_posts USING btree (parent_id);


--
-- Name: idx_forum_posts_topic_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_posts_topic_id ON public.forum_posts USING btree (topic_id);


--
-- Name: idx_forum_posts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_posts_user_id ON public.forum_posts USING btree (user_id);


--
-- Name: idx_forum_similar_a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_similar_a ON public.forum_similar_topics USING btree (topic_a_id);


--
-- Name: idx_forum_similar_b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_similar_b ON public.forum_similar_topics USING btree (topic_b_id);


--
-- Name: idx_forum_similar_score; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_similar_score ON public.forum_similar_topics USING btree (similarity_score DESC);


--
-- Name: idx_forum_topics_title_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_topics_title_trgm ON public.forum_topics USING gin (title public.gin_trgm_ops);


--
-- Name: idx_message_reactions_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_reactions_message_id ON public.message_reactions USING btree (message_id);


--
-- Name: idx_messages_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_conversation_id ON public.messages USING btree (conversation_id);


--
-- Name: idx_messages_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_created_at ON public.messages USING btree (created_at);


--
-- Name: idx_messages_forwarded_from_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_forwarded_from_id ON public.messages USING btree (forwarded_from_id);


--
-- Name: idx_messages_sender_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_sender_id ON public.messages USING btree (sender_id);


--
-- Name: idx_moderator_permissions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moderator_permissions_user_id ON public.moderator_permissions USING btree (user_id);


--
-- Name: idx_payments_user_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_user_date ON public.payments USING btree (user_id, created_at DESC);


--
-- Name: idx_qa_comments_ticket; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_comments_ticket ON public.qa_comments USING btree (ticket_id);


--
-- Name: idx_qa_tester_stats_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tester_stats_tier ON public.qa_tester_stats USING btree (tier);


--
-- Name: idx_qa_tickets_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_category ON public.qa_tickets USING btree (category);


--
-- Name: idx_qa_tickets_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_created ON public.qa_tickets USING btree (created_at DESC);


--
-- Name: idx_qa_tickets_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_priority ON public.qa_tickets USING btree (priority_score DESC);


--
-- Name: idx_qa_tickets_reporter; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_reporter ON public.qa_tickets USING btree (reporter_id);


--
-- Name: idx_qa_tickets_severity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_severity ON public.qa_tickets USING btree (severity);


--
-- Name: idx_qa_tickets_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_status ON public.qa_tickets USING btree (status);


--
-- Name: idx_qa_tickets_title_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_tickets_title_trgm ON public.qa_tickets USING gin (title public.gin_trgm_ops);


--
-- Name: idx_qa_votes_ticket; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qa_votes_ticket ON public.qa_votes USING btree (ticket_id);


--
-- Name: idx_radio_bids_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_bids_slot ON public.radio_bids USING btree (slot_id, amount DESC);


--
-- Name: idx_radio_listens_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listens_track ON public.radio_listens USING btree (track_id, created_at DESC);


--
-- Name: idx_radio_listens_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listens_user ON public.radio_listens USING btree (user_id, created_at DESC);


--
-- Name: idx_radio_predictions_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_predictions_track ON public.radio_predictions USING btree (track_id, status);


--
-- Name: idx_radio_predictions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_predictions_user ON public.radio_predictions USING btree (user_id, status);


--
-- Name: idx_radio_queue_genre; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_queue_genre ON public.radio_queue USING btree (genre_id) WHERE (NOT is_played);


--
-- Name: idx_radio_queue_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_queue_position ON public.radio_queue USING btree ("position") WHERE (NOT is_played);


--
-- Name: idx_radio_slots_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_slots_status ON public.radio_slots USING btree (status, starts_at);


--
-- Name: idx_rep_events_user_type_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_user_type_date ON public.reputation_events USING btree (user_id, event_type, created_at DESC);


--
-- Name: idx_rep_events_user_xp_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_user_xp_date ON public.reputation_events USING btree (user_id, created_at) WHERE (xp_delta > 0);


--
-- Name: idx_reputation_events_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reputation_events_type ON public.reputation_events USING btree (event_type);


--
-- Name: idx_reputation_events_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reputation_events_user ON public.reputation_events USING btree (user_id, created_at DESC);


--
-- Name: idx_role_change_logs_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_change_logs_action ON public.role_change_logs USING btree (action);


--
-- Name: idx_role_change_logs_changed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_change_logs_changed_by ON public.role_change_logs USING btree (changed_by);


--
-- Name: idx_role_change_logs_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_change_logs_created_at ON public.role_change_logs USING btree (created_at DESC);


--
-- Name: idx_role_invitations_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_invitations_status ON public.role_invitations USING btree (status);


--
-- Name: idx_role_invitations_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_invitations_user_id ON public.role_invitations USING btree (user_id);


--
-- Name: idx_track_quality_score; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_quality_score ON public.track_quality_scores USING btree (quality_score);


--
-- Name: idx_track_quality_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_quality_user ON public.track_quality_scores USING btree (user_id);


--
-- Name: idx_track_reactions_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_reactions_track ON public.track_reactions USING btree (track_id);


--
-- Name: idx_track_reactions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_reactions_user ON public.track_reactions USING btree (user_id);


--
-- Name: idx_track_votes_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_track_votes_recent ON public.track_votes USING btree (track_id, created_at DESC);


--
-- Name: idx_tracks_mod_status_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracks_mod_status_date ON public.tracks USING btree (moderation_status, created_at DESC);


--
-- Name: idx_tracks_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracks_position ON public.tracks USING btree (user_id, "position");


--
-- Name: idx_tracks_user_mod; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracks_user_mod ON public.tracks USING btree (user_id, moderation_status);


--
-- Name: idx_user_achievements_achievement; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_achievements_achievement ON public.user_achievements USING btree (achievement_id);


--
-- Name: idx_user_achievements_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_achievements_user ON public.user_achievements USING btree (user_id);


--
-- Name: idx_user_blocks_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_blocks_user ON public.user_blocks USING btree (user_id);


--
-- Name: idx_user_roles_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_roles_user_id ON public.user_roles USING btree (user_id);


--
-- Name: idx_verification_requests_one_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_verification_requests_one_pending ON public.verification_requests USING btree (user_id) WHERE (status = 'pending'::text);


--
-- Name: users on_auth_user_created; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


--
-- Name: users trg_protect_superadmin_auth_delete; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER trg_protect_superadmin_auth_delete BEFORE DELETE ON auth.users FOR EACH ROW EXECUTE FUNCTION public.protect_superadmin_auth_delete();


--
-- Name: users trg_protect_superadmin_auth_update; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER trg_protect_superadmin_auth_update BEFORE UPDATE ON auth.users FOR EACH ROW EXECUTE FUNCTION public.protect_superadmin_auth_update();


--
-- Name: user_roles protect_super_admin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_super_admin BEFORE INSERT OR DELETE OR UPDATE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION public.protect_super_admin_role();


--
-- Name: contests trg_check_achievements; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_check_achievements AFTER UPDATE ON public.contests FOR EACH ROW EXECUTE FUNCTION public.check_achievements_after_finalize();


--
-- Name: forum_posts trg_forum_post_stats; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_forum_post_stats AFTER INSERT OR DELETE ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION public.forum_update_topic_on_post();


--
-- Name: forum_topics trg_forum_topic_stats; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_forum_topic_stats AFTER INSERT OR DELETE ON public.forum_topics FOR EACH ROW EXECUTE FUNCTION public.forum_update_category_on_topic();


--
-- Name: forum_posts trg_forum_user_stats_post; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_forum_user_stats_post AFTER INSERT ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION public.forum_update_user_stats_on_post();


--
-- Name: forum_topics trg_forum_user_stats_topic; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_forum_user_stats_topic AFTER INSERT ON public.forum_topics FOR EACH ROW EXECUTE FUNCTION public.forum_update_user_stats_on_topic();


--
-- Name: contest_entries trg_notify_contest_entries; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_contest_entries AFTER INSERT OR DELETE OR UPDATE ON public.contest_entries FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: contest_entry_comments trg_notify_contest_entry_comments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_contest_entry_comments AFTER INSERT OR DELETE OR UPDATE ON public.contest_entry_comments FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: contest_winners trg_notify_contest_winners; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_contest_winners AFTER INSERT OR DELETE OR UPDATE ON public.contest_winners FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: conversation_participants trg_notify_conversation_participants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_conversation_participants AFTER INSERT OR DELETE OR UPDATE ON public.conversation_participants FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: conversations trg_notify_conversations; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_conversations AFTER INSERT OR DELETE OR UPDATE ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: forum_posts trg_notify_forum_posts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_forum_posts AFTER INSERT OR DELETE OR UPDATE ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: forum_topics trg_notify_forum_topics; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_forum_topics AFTER INSERT OR DELETE OR UPDATE ON public.forum_topics FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: message_reactions trg_notify_message_reactions; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_message_reactions AFTER INSERT OR DELETE OR UPDATE ON public.message_reactions FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: messages trg_notify_messages; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_messages AFTER INSERT OR DELETE OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: notifications trg_notify_notifications; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_notifications AFTER INSERT OR DELETE OR UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: support_tickets trg_notify_support_tickets; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_support_tickets AFTER INSERT OR DELETE OR UPDATE ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: ticket_messages trg_notify_ticket_messages; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_ticket_messages AFTER INSERT OR DELETE OR UPDATE ON public.ticket_messages FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: track_addons trg_notify_track_addons; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_track_addons AFTER INSERT OR DELETE OR UPDATE ON public.track_addons FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: track_comments trg_notify_track_comments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_track_comments AFTER INSERT OR DELETE OR UPDATE ON public.track_comments FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: tracks trg_notify_tracks; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_tracks AFTER INSERT OR DELETE OR UPDATE ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();


--
-- Name: contest_votes trg_prevent_self_vote; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_self_vote BEFORE INSERT ON public.contest_votes FOR EACH ROW EXECUTE FUNCTION public.prevent_self_vote();


--
-- Name: profiles trg_protect_superadmin_profile_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_superadmin_profile_delete BEFORE DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_superadmin_profile_delete();


--
-- Name: profiles trg_protect_superadmin_profile_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_superadmin_profile_update BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_superadmin_profile_update();


--
-- Name: user_roles trg_protect_superadmin_role_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_superadmin_role_delete BEFORE DELETE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION public.protect_superadmin_role_delete();


--
-- Name: qa_tickets trg_qa_ticket_number; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_qa_ticket_number BEFORE INSERT ON public.qa_tickets FOR EACH ROW WHEN ((new.ticket_number IS NULL)) EXECUTE FUNCTION public.qa_generate_ticket_number();


--
-- Name: qa_tickets trg_qa_tickets_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_qa_tickets_updated BEFORE UPDATE ON public.qa_tickets FOR EACH ROW EXECUTE FUNCTION public.qa_update_timestamp();


--
-- Name: contest_votes trg_update_total_votes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_total_votes AFTER INSERT OR DELETE ON public.contest_votes FOR EACH ROW EXECUTE FUNCTION public.update_total_votes_received();


--
-- Name: track_votes trigger_check_voting_eligibility; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_check_voting_eligibility BEFORE INSERT ON public.track_votes FOR EACH ROW EXECUTE FUNCTION public.check_voting_eligibility();


--
-- Name: profiles update_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: tracks update_tracks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_tracks_updated_at BEFORE UPDATE ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ad_campaign_slots ad_campaign_slots_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_slots
    ADD CONSTRAINT ad_campaign_slots_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: ad_campaign_slots ad_campaign_slots_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_slots
    ADD CONSTRAINT ad_campaign_slots_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.ad_slots(id) ON DELETE CASCADE;


--
-- Name: ad_impressions ad_impressions_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE SET NULL;


--
-- Name: ad_impressions ad_impressions_creative_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_creative_id_fkey FOREIGN KEY (creative_id) REFERENCES public.ad_creatives(id) ON DELETE SET NULL;


--
-- Name: ad_targeting ad_targeting_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_targeting
    ADD CONSTRAINT ad_targeting_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: announcement_dismissals announcement_dismissals_announcement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_announcement_id_fkey FOREIGN KEY (announcement_id) REFERENCES public.admin_announcements(id) ON DELETE CASCADE;


--
-- Name: attribution_shares attribution_shares_pool_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_shares
    ADD CONSTRAINT attribution_shares_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.attribution_pools(id) ON DELETE CASCADE;


--
-- Name: beat_purchases beat_purchases_beat_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beat_purchases
    ADD CONSTRAINT beat_purchases_beat_id_fkey FOREIGN KEY (beat_id) REFERENCES public.store_beats(id) ON DELETE SET NULL;


--
-- Name: beat_purchases beat_purchases_buyer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beat_purchases
    ADD CONSTRAINT beat_purchases_buyer_id_fkey FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: beat_purchases beat_purchases_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beat_purchases
    ADD CONSTRAINT beat_purchases_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: comments comments_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: comments comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: contest_entries contest_entries_contest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entries
    ADD CONSTRAINT contest_entries_contest_id_fkey FOREIGN KEY (contest_id) REFERENCES public.contests(id) ON DELETE CASCADE;


--
-- Name: contest_entries contest_entries_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entries
    ADD CONSTRAINT contest_entries_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: contest_entries contest_entries_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entries
    ADD CONSTRAINT contest_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: contest_entry_comments contest_entry_comments_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entry_comments
    ADD CONSTRAINT contest_entry_comments_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.contest_entries(id) ON DELETE CASCADE;


--
-- Name: contest_entry_comments contest_entry_comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_entry_comments
    ADD CONSTRAINT contest_entry_comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: contest_ratings contest_ratings_league_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_ratings
    ADD CONSTRAINT contest_ratings_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.contest_leagues(id);


--
-- Name: contest_ratings contest_ratings_season_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_ratings
    ADD CONSTRAINT contest_ratings_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.contest_seasons(id);


--
-- Name: contest_user_achievements contest_user_achievements_achievement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_user_achievements
    ADD CONSTRAINT contest_user_achievements_achievement_id_fkey FOREIGN KEY (achievement_id) REFERENCES public.contest_achievements(id) ON DELETE CASCADE;


--
-- Name: contest_winners contest_winners_contest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_winners
    ADD CONSTRAINT contest_winners_contest_id_fkey FOREIGN KEY (contest_id) REFERENCES public.contests(id) ON DELETE CASCADE;


--
-- Name: contest_winners contest_winners_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_winners
    ADD CONSTRAINT contest_winners_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.contest_entries(id) ON DELETE SET NULL;


--
-- Name: contest_winners contest_winners_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contest_winners
    ADD CONSTRAINT contest_winners_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: contests contests_season_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contests
    ADD CONSTRAINT contests_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.contest_seasons(id) ON DELETE SET NULL;


--
-- Name: conversation_participants conversation_participants_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants
    ADD CONSTRAINT conversation_participants_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: conversation_participants conversation_participants_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants
    ADD CONSTRAINT conversation_participants_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: distribution_requests distribution_requests_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_requests
    ADD CONSTRAINT distribution_requests_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: distribution_requests distribution_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_requests
    ADD CONSTRAINT distribution_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: email_verifications email_verifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: follows follows_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: follows follows_following_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_following_id_fkey FOREIGN KEY (following_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: forum_bookmarks forum_bookmarks_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_bookmarks
    ADD CONSTRAINT forum_bookmarks_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_category_subscriptions forum_category_subscriptions_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_category_subscriptions
    ADD CONSTRAINT forum_category_subscriptions_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.forum_categories(id) ON DELETE CASCADE;


--
-- Name: forum_citations forum_citations_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.forum_knowledge_articles(id) ON DELETE CASCADE;


--
-- Name: forum_citations forum_citations_citing_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_citing_post_id_fkey FOREIGN KEY (citing_post_id) REFERENCES public.forum_posts(id) ON DELETE CASCADE;


--
-- Name: forum_citations forum_citations_citing_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_citations
    ADD CONSTRAINT forum_citations_citing_topic_id_fkey FOREIGN KEY (citing_topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_content_purchases forum_content_purchases_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_content_purchases
    ADD CONSTRAINT forum_content_purchases_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_knowledge_articles forum_knowledge_articles_source_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_knowledge_articles
    ADD CONSTRAINT forum_knowledge_articles_source_topic_id_fkey FOREIGN KEY (source_topic_id) REFERENCES public.forum_topics(id) ON DELETE SET NULL;


--
-- Name: forum_poll_options forum_poll_options_poll_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_options
    ADD CONSTRAINT forum_poll_options_poll_id_fkey FOREIGN KEY (poll_id) REFERENCES public.forum_polls(id) ON DELETE CASCADE;


--
-- Name: forum_poll_votes forum_poll_votes_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_votes
    ADD CONSTRAINT forum_poll_votes_option_id_fkey FOREIGN KEY (option_id) REFERENCES public.forum_poll_options(id) ON DELETE CASCADE;


--
-- Name: forum_poll_votes forum_poll_votes_poll_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_poll_votes
    ADD CONSTRAINT forum_poll_votes_poll_id_fkey FOREIGN KEY (poll_id) REFERENCES public.forum_polls(id) ON DELETE CASCADE;


--
-- Name: forum_polls forum_polls_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_polls
    ADD CONSTRAINT forum_polls_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_post_reactions forum_post_reactions_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_reactions
    ADD CONSTRAINT forum_post_reactions_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.forum_posts(id) ON DELETE CASCADE;


--
-- Name: forum_post_votes forum_post_votes_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_post_votes
    ADD CONSTRAINT forum_post_votes_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.forum_posts(id) ON DELETE CASCADE;


--
-- Name: forum_posts forum_posts_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_posts
    ADD CONSTRAINT forum_posts_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.forum_posts(id) ON DELETE SET NULL;


--
-- Name: forum_posts forum_posts_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_posts
    ADD CONSTRAINT forum_posts_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_posts forum_posts_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_posts
    ADD CONSTRAINT forum_posts_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE SET NULL;


--
-- Name: forum_posts forum_posts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_posts
    ADD CONSTRAINT forum_posts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: forum_premium_content forum_premium_content_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_premium_content
    ADD CONSTRAINT forum_premium_content_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_similar_topics forum_similar_topics_topic_a_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_similar_topics
    ADD CONSTRAINT forum_similar_topics_topic_a_id_fkey FOREIGN KEY (topic_a_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_similar_topics forum_similar_topics_topic_b_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_similar_topics
    ADD CONSTRAINT forum_similar_topics_topic_b_id_fkey FOREIGN KEY (topic_b_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_topic_boosts forum_topic_boosts_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_boosts
    ADD CONSTRAINT forum_topic_boosts_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_topic_cluster_members forum_topic_cluster_members_cluster_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_cluster_members
    ADD CONSTRAINT forum_topic_cluster_members_cluster_id_fkey FOREIGN KEY (cluster_id) REFERENCES public.forum_topic_clusters(id) ON DELETE CASCADE;


--
-- Name: forum_topic_cluster_members forum_topic_cluster_members_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_cluster_members
    ADD CONSTRAINT forum_topic_cluster_members_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_topic_clusters forum_topic_clusters_representative_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_clusters
    ADD CONSTRAINT forum_topic_clusters_representative_topic_id_fkey FOREIGN KEY (representative_topic_id) REFERENCES public.forum_topics(id) ON DELETE SET NULL;


--
-- Name: forum_topic_subscriptions forum_topic_subscriptions_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_subscriptions
    ADD CONSTRAINT forum_topic_subscriptions_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_topic_tags forum_topic_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_tags
    ADD CONSTRAINT forum_topic_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.forum_tags(id) ON DELETE CASCADE;


--
-- Name: forum_topic_tags forum_topic_tags_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topic_tags
    ADD CONSTRAINT forum_topic_tags_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;


--
-- Name: forum_topics forum_topics_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topics
    ADD CONSTRAINT forum_topics_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.forum_categories(id) ON DELETE CASCADE;


--
-- Name: forum_topics forum_topics_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topics
    ADD CONSTRAINT forum_topics_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: generation_logs generation_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_logs
    ADD CONSTRAINT generation_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: genres genres_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genres
    ADD CONSTRAINT genres_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.genre_categories(id) ON DELETE CASCADE;


--
-- Name: item_purchases item_purchases_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_purchases
    ADD CONSTRAINT item_purchases_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.store_items(id) ON DELETE SET NULL;


--
-- Name: lyrics lyrics_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lyrics
    ADD CONSTRAINT lyrics_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: maintenance_whitelist maintenance_whitelist_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.maintenance_whitelist
    ADD CONSTRAINT maintenance_whitelist_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_forwarded_from_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_forwarded_from_id_fkey FOREIGN KEY (forwarded_from_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messages messages_receiver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_receiver_id_fkey FOREIGN KEY (receiver_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payout_requests payout_requests_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_requests
    ADD CONSTRAINT payout_requests_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: personas personas_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personas
    ADD CONSTRAINT personas_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: playlist_tracks playlist_tracks_playlist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.playlist_tracks
    ADD CONSTRAINT playlist_tracks_playlist_id_fkey FOREIGN KEY (playlist_id) REFERENCES public.playlists(id) ON DELETE CASCADE;


--
-- Name: playlist_tracks playlist_tracks_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.playlist_tracks
    ADD CONSTRAINT playlist_tracks_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: playlists playlists_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.playlists
    ADD CONSTRAINT playlists_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: prompts prompts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: qa_comments qa_comments_ticket_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_comments
    ADD CONSTRAINT qa_comments_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES public.qa_tickets(id) ON DELETE CASCADE;


--
-- Name: qa_tickets qa_tickets_duplicate_of_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_tickets
    ADD CONSTRAINT qa_tickets_duplicate_of_fkey FOREIGN KEY (duplicate_of) REFERENCES public.qa_tickets(id);


--
-- Name: qa_votes qa_votes_ticket_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qa_votes
    ADD CONSTRAINT qa_votes_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES public.qa_tickets(id) ON DELETE CASCADE;


--
-- Name: radio_bids radio_bids_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_bids
    ADD CONSTRAINT radio_bids_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.radio_slots(id) ON DELETE CASCADE;


--
-- Name: radio_bids radio_bids_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_bids
    ADD CONSTRAINT radio_bids_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id);


--
-- Name: radio_listens radio_listens_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listens
    ADD CONSTRAINT radio_listens_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: radio_predictions radio_predictions_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_predictions
    ADD CONSTRAINT radio_predictions_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id);


--
-- Name: radio_queue radio_queue_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_queue
    ADD CONSTRAINT radio_queue_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: radio_queue radio_queue_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_queue
    ADD CONSTRAINT radio_queue_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(user_id);


--
-- Name: radio_slots radio_slots_winner_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_slots
    ADD CONSTRAINT radio_slots_winner_track_id_fkey FOREIGN KEY (winner_track_id) REFERENCES public.tracks(id);


--
-- Name: referrals referrals_referred_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_referred_id_fkey FOREIGN KEY (referred_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: referrals referrals_referrer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_referrer_id_fkey FOREIGN KEY (referrer_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: reputation_events reputation_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reputation_events
    ADD CONSTRAINT reputation_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: role_change_logs role_change_logs_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_change_logs
    ADD CONSTRAINT role_change_logs_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: role_change_logs role_change_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_change_logs
    ADD CONSTRAINT role_change_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: role_invitation_permissions role_invitation_permissions_invitation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_invitation_permissions
    ADD CONSTRAINT role_invitation_permissions_invitation_id_fkey FOREIGN KEY (invitation_id) REFERENCES public.role_invitations(id) ON DELETE CASCADE;


--
-- Name: role_invitations role_invitations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_invitations
    ADD CONSTRAINT role_invitations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: seller_earnings seller_earnings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_earnings
    ADD CONSTRAINT seller_earnings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: store_beats store_beats_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_beats
    ADD CONSTRAINT store_beats_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: store_beats store_beats_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_beats
    ADD CONSTRAINT store_beats_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: support_messages support_messages_ticket_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_messages
    ADD CONSTRAINT support_messages_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES public.support_tickets(id) ON DELETE CASCADE;


--
-- Name: support_messages support_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_messages
    ADD CONSTRAINT support_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: support_tickets support_tickets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: ticket_messages ticket_messages_ticket_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticket_messages
    ADD CONSTRAINT ticket_messages_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES public.support_tickets(id) ON DELETE CASCADE;


--
-- Name: ticket_messages ticket_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticket_messages
    ADD CONSTRAINT ticket_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: track_addons track_addons_addon_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_addons
    ADD CONSTRAINT track_addons_addon_service_id_fkey FOREIGN KEY (addon_service_id) REFERENCES public.addon_services(id);


--
-- Name: track_addons track_addons_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_addons
    ADD CONSTRAINT track_addons_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_addons track_addons_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_addons
    ADD CONSTRAINT track_addons_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: track_bookmarks track_bookmarks_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_bookmarks
    ADD CONSTRAINT track_bookmarks_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_bookmarks track_bookmarks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_bookmarks
    ADD CONSTRAINT track_bookmarks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: track_comments track_comments_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_comments
    ADD CONSTRAINT track_comments_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_comments track_comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_comments
    ADD CONSTRAINT track_comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: track_feed_scores track_feed_scores_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_feed_scores
    ADD CONSTRAINT track_feed_scores_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_likes track_likes_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_likes
    ADD CONSTRAINT track_likes_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_likes track_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_likes
    ADD CONSTRAINT track_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: track_reactions track_reactions_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reactions
    ADD CONSTRAINT track_reactions_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: track_reactions track_reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reactions
    ADD CONSTRAINT track_reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: track_reports track_reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reports
    ADD CONSTRAINT track_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: track_reports track_reports_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.track_reports
    ADD CONSTRAINT track_reports_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: tracks tracks_artist_style_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_artist_style_id_fkey FOREIGN KEY (artist_style_id) REFERENCES public.artist_styles(id);


--
-- Name: tracks tracks_genre_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_genre_id_fkey FOREIGN KEY (genre_id) REFERENCES public.genres(id);


--
-- Name: tracks tracks_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.ai_models(id);


--
-- Name: tracks tracks_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.templates(id);


--
-- Name: tracks tracks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tracks tracks_vocal_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracks
    ADD CONSTRAINT tracks_vocal_type_id_fkey FOREIGN KEY (vocal_type_id) REFERENCES public.vocal_types(id);


--
-- Name: user_achievements user_achievements_achievement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_achievements
    ADD CONSTRAINT user_achievements_achievement_id_fkey FOREIGN KEY (achievement_id) REFERENCES public.achievements(id) ON DELETE CASCADE;


--
-- Name: user_blocks user_blocks_blocked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_blocked_by_fkey FOREIGN KEY (blocked_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: user_blocks user_blocks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_challenges user_challenges_challenge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_challenges
    ADD CONSTRAINT user_challenges_challenge_id_fkey FOREIGN KEY (challenge_id) REFERENCES public.challenges(id) ON DELETE CASCADE;


--
-- Name: user_follows user_follows_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_follows
    ADD CONSTRAINT user_follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_follows user_follows_following_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_follows
    ADD CONSTRAINT user_follows_following_id_fkey FOREIGN KEY (following_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_prompts user_prompts_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_prompts
    ADD CONSTRAINT user_prompts_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE SET NULL;


--
-- Name: user_prompts user_prompts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_prompts
    ADD CONSTRAINT user_prompts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: verification_requests verification_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_requests
    ADD CONSTRAINT verification_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: messages Admin can view all messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admin can view all messages" ON public.messages FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));


--
-- Name: role_invitations Admins can create invitations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can create invitations" ON public.role_invitations FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: tracks Admins can delete all tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete all tracks" ON public.tracks FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role]))))));


--
-- Name: permission_categories Admins can delete categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete categories" ON public.permission_categories FOR DELETE USING (public.is_admin(auth.uid()));


--
-- Name: conversations Admins can delete conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete conversations" ON public.conversations FOR DELETE TO authenticated USING (public.is_admin(auth.uid()));


--
-- Name: role_invitation_permissions Admins can delete invitation permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete invitation permissions" ON public.role_invitation_permissions FOR DELETE USING (public.is_admin(auth.uid()));


--
-- Name: moderator_permissions Admins can delete permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete permissions" ON public.moderator_permissions FOR DELETE USING (public.is_admin(auth.uid()));


--
-- Name: moderator_presets Admins can delete presets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete presets" ON public.moderator_presets FOR DELETE USING (public.is_admin(auth.uid()));


--
-- Name: user_roles Admins can delete roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete roles" ON public.user_roles FOR DELETE TO authenticated USING (public.is_admin(auth.uid()));


--
-- Name: permission_categories Admins can insert categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert categories" ON public.permission_categories FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: role_change_logs Admins can insert logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert logs" ON public.role_change_logs FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: moderator_permissions Admins can insert permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert permissions" ON public.moderator_permissions FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: moderator_presets Admins can insert presets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert presets" ON public.moderator_presets FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: user_roles Admins can insert roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert roles" ON public.user_roles FOR INSERT TO authenticated WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: role_invitation_permissions Admins can manage invitation permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage invitation permissions" ON public.role_invitation_permissions FOR INSERT WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: contest_jury Admins can manage jury; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage jury" ON public.contest_jury USING (public.is_admin(auth.uid()));


--
-- Name: verification_requests Admins can manage verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage verification requests" ON public.verification_requests USING (public.is_admin(auth.uid()));


--
-- Name: tracks Admins can update all tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update all tracks" ON public.tracks FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role, 'moderator'::public.app_role]))))));


--
-- Name: permission_categories Admins can update categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update categories" ON public.permission_categories FOR UPDATE USING (public.is_admin(auth.uid()));


--
-- Name: conversations Admins can update conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update conversations" ON public.conversations FOR UPDATE TO authenticated USING ((public.is_admin(auth.uid()) OR public.is_participant_in_conversation(auth.uid(), id)));


--
-- Name: moderator_permissions Admins can update permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update permissions" ON public.moderator_permissions FOR UPDATE USING (public.is_admin(auth.uid()));


--
-- Name: moderator_presets Admins can update presets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update presets" ON public.moderator_presets FOR UPDATE USING (public.is_admin(auth.uid()));


--
-- Name: track_promotions Admins can view all promotions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all promotions" ON public.track_promotions FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: user_roles Admins can view all roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all roles" ON public.user_roles FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));


--
-- Name: tracks Admins can view all tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all tracks" ON public.tracks FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role, 'moderator'::public.app_role]))))));


--
-- Name: forum_posts Admins delete posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete posts" ON public.forum_posts FOR DELETE USING (true);


--
-- Name: contest_achievements Anyone can view achievements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view achievements" ON public.contest_achievements FOR SELECT USING (true);


--
-- Name: permission_categories Anyone can view active categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view active categories" ON public.permission_categories FOR SELECT USING (((is_active = true) OR public.is_admin(auth.uid())));


--
-- Name: moderator_presets Anyone can view active presets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view active presets" ON public.moderator_presets FOR SELECT USING (((is_active = true) OR public.is_admin(auth.uid())));


--
-- Name: ai_models Anyone can view ai_models; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view ai_models" ON public.ai_models FOR SELECT USING (true);


--
-- Name: artist_styles Anyone can view artist_styles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view artist_styles" ON public.artist_styles FOR SELECT USING (true);


--
-- Name: genre_categories Anyone can view genre_categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view genre_categories" ON public.genre_categories FOR SELECT USING (true);


--
-- Name: genres Anyone can view genres; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view genres" ON public.genres FOR SELECT USING (true);


--
-- Name: contest_leagues Anyone can view leagues; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view leagues" ON public.contest_leagues FOR SELECT USING (true);


--
-- Name: contest_ratings Anyone can view ratings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view ratings" ON public.contest_ratings FOR SELECT USING (true);


--
-- Name: contest_seasons Anyone can view seasons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view seasons" ON public.contest_seasons FOR SELECT USING (true);


--
-- Name: templates Anyone can view templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view templates" ON public.templates FOR SELECT USING (true);


--
-- Name: track_bookmarks Anyone can view track bookmarks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view track bookmarks" ON public.track_bookmarks FOR SELECT USING (true);


--
-- Name: contest_user_achievements Anyone can view user achievements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view user achievements" ON public.contest_user_achievements FOR SELECT USING (true);


--
-- Name: vocal_types Anyone can view vocal_types; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view vocal_types" ON public.vocal_types FOR SELECT USING (true);


--
-- Name: forum_posts Authenticated users create posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users create posts" ON public.forum_posts FOR INSERT WITH CHECK (true);


--
-- Name: conversations Functions can insert conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Functions can insert conversations" ON public.conversations FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: conversation_participants Functions can insert participants; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Functions can insert participants" ON public.conversation_participants FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: role_change_logs Only admins can view logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can view logs" ON public.role_change_logs FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: message_reactions Participants can add reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can add reactions" ON public.message_reactions FOR INSERT TO authenticated WITH CHECK (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.messages m
  WHERE ((m.id = message_reactions.message_id) AND public.is_participant_in_conversation(auth.uid(), m.conversation_id))))));


--
-- Name: messages Participants can send messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can send messages" ON public.messages FOR INSERT TO authenticated WITH CHECK (((sender_id = auth.uid()) AND public.is_participant_in_conversation(auth.uid(), conversation_id)));


--
-- Name: conversations Participants can view conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can view conversations" ON public.conversations FOR SELECT TO authenticated USING ((public.is_participant_in_conversation(auth.uid(), id) OR public.is_admin(auth.uid())));


--
-- Name: messages Participants can view messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can view messages" ON public.messages FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND public.is_participant_in_conversation(auth.uid(), conversation_id)));


--
-- Name: message_reactions Participants can view reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can view reactions" ON public.message_reactions FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.messages m
  WHERE ((m.id = message_reactions.message_id) AND public.is_participant_in_conversation(auth.uid(), m.conversation_id)))) OR public.is_admin(auth.uid())));


--
-- Name: messages Prevent messages in closed conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Prevent messages in closed conversations" ON public.messages AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK ((NOT (EXISTS ( SELECT 1
   FROM public.conversations
  WHERE ((conversations.id = messages.conversation_id) AND (conversations.status = 'closed'::text))))));


--
-- Name: role_change_logs Super admins can view all logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins can view all logs" ON public.role_change_logs FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: track_bookmarks Users can bookmark tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can bookmark tracks" ON public.track_bookmarks FOR INSERT WITH CHECK (((auth.uid() = user_id) OR public.is_admin(auth.uid())));


--
-- Name: verification_requests Users can create verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can create verification requests" ON public.verification_requests FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: track_likes Users can delete own likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own likes" ON public.track_likes FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: track_deposits Users can delete own non-completed deposits; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own non-completed deposits" ON public.track_deposits FOR DELETE USING (((auth.uid() = user_id) AND (status = ANY (ARRAY['pending'::text, 'processing'::text, 'failed'::text]))));


--
-- Name: tracks Users can delete own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own tracks" ON public.tracks FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: track_likes Users can insert own likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own likes" ON public.track_likes FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: profiles Users can insert own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: tracks Users can insert own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own tracks" ON public.tracks FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: conversation_participants Users can leave conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can leave conversations" ON public.conversation_participants FOR DELETE TO authenticated USING (((user_id = auth.uid()) OR public.is_admin(auth.uid())));


--
-- Name: message_reactions Users can remove own reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can remove own reactions" ON public.message_reactions FOR DELETE TO authenticated USING ((user_id = auth.uid()));


--
-- Name: role_invitations Users can respond to own invitations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can respond to own invitations" ON public.role_invitations FOR UPDATE USING (((user_id = auth.uid()) OR public.is_admin(auth.uid())));


--
-- Name: messages Users can soft delete own messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can soft delete own messages" ON public.messages FOR UPDATE TO authenticated USING ((sender_id = auth.uid())) WITH CHECK ((sender_id = auth.uid()));


--
-- Name: track_bookmarks Users can unbookmark tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can unbookmark tracks" ON public.track_bookmarks FOR DELETE USING (((auth.uid() = user_id) OR public.is_admin(auth.uid())));


--
-- Name: conversation_participants Users can update own participation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own participation" ON public.conversation_participants FOR UPDATE TO authenticated USING ((user_id = auth.uid()));


--
-- Name: verification_requests Users can update own pending requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own pending requests" ON public.verification_requests FOR UPDATE USING (((auth.uid() = user_id) AND (status = 'pending'::text))) WITH CHECK (((auth.uid() = user_id) AND (status = 'pending'::text)));


--
-- Name: profiles Users can update own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: tracks Users can update own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own tracks" ON public.tracks FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: track_likes Users can view all likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all likes" ON public.track_likes FOR SELECT USING (true);


--
-- Name: profiles Users can view all profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all profiles" ON public.profiles FOR SELECT USING (true);


--
-- Name: role_invitation_permissions Users can view own invitation permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own invitation permissions" ON public.role_invitation_permissions FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.role_invitations ri
  WHERE ((ri.id = role_invitation_permissions.invitation_id) AND ((ri.user_id = auth.uid()) OR public.is_admin(auth.uid()))))));


--
-- Name: role_invitations Users can view own invitations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own invitations" ON public.role_invitations FOR SELECT USING (((user_id = auth.uid()) OR (invited_by = auth.uid()) OR public.is_admin(auth.uid())));


--
-- Name: conversation_participants Users can view own participations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own participations" ON public.conversation_participants FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR public.is_admin(auth.uid()) OR public.is_participant_in_conversation(auth.uid(), conversation_id)));


--
-- Name: moderator_permissions Users can view own permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own permissions" ON public.moderator_permissions FOR SELECT USING (((user_id = auth.uid()) OR public.is_admin(auth.uid())));


--
-- Name: user_roles Users can view own role; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own role" ON public.user_roles FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: tracks Users can view own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own tracks" ON public.tracks FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: verification_requests Users can view own verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own verification requests" ON public.verification_requests FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: tracks Users can view public tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view public tracks" ON public.tracks FOR SELECT USING ((is_public = true));


--
-- Name: forum_posts Users update own posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users update own posts" ON public.forum_posts FOR UPDATE USING (true);


--
-- Name: forum_posts View visible posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "View visible posts" ON public.forum_posts FOR SELECT USING (true);


--
-- Name: achievements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;

--
-- Name: achievements achievements_public_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY achievements_public_read ON public.achievements FOR SELECT USING (true);


--
-- Name: maintenance_whitelist admins_read_whitelist; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_read_whitelist ON public.maintenance_whitelist FOR SELECT USING (public.is_admin((current_setting('request.jwt.claim.sub'::text, true))::uuid));


--
-- Name: ai_models; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_models ENABLE ROW LEVEL SECURITY;

--
-- Name: artist_styles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.artist_styles ENABLE ROW LEVEL SECURITY;

--
-- Name: attribution_pools; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attribution_pools ENABLE ROW LEVEL SECURITY;

--
-- Name: attribution_shares; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attribution_shares ENABLE ROW LEVEL SECURITY;

--
-- Name: contest_achievements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contest_achievements ENABLE ROW LEVEL SECURITY;

--
-- Name: contest_leagues; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contest_leagues ENABLE ROW LEVEL SECURITY;

--
-- Name: contest_ratings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contest_ratings ENABLE ROW LEVEL SECURITY;

--
-- Name: contest_seasons; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contest_seasons ENABLE ROW LEVEL SECURITY;

--
-- Name: contest_user_achievements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contest_user_achievements ENABLE ROW LEVEL SECURITY;

--
-- Name: conversation_participants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversation_participants ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: creator_earnings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.creator_earnings ENABLE ROW LEVEL SECURITY;

--
-- Name: economy_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.economy_config ENABLE ROW LEVEL SECURITY;

--
-- Name: economy_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.economy_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: feed_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.feed_config ENABLE ROW LEVEL SECURITY;

--
-- Name: feed_config feed_config_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY feed_config_read ON public.feed_config FOR SELECT USING (true);


--
-- Name: track_feed_scores feed_scores_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY feed_scores_read ON public.track_feed_scores FOR SELECT USING (true);


--
-- Name: forum_citations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_citations ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_content_purchases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_content_purchases ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_content_quality; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_content_quality ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_hub_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_hub_config ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_knowledge_articles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_knowledge_articles ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_premium_content; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_premium_content ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_similar_topics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_similar_topics ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_topic_boosts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_topic_boosts ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_topic_cluster_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_topic_cluster_members ENABLE ROW LEVEL SECURITY;

--
-- Name: forum_topic_clusters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.forum_topic_clusters ENABLE ROW LEVEL SECURITY;

--
-- Name: genre_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.genre_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: genres; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.genres ENABLE ROW LEVEL SECURITY;

--
-- Name: maintenance_whitelist; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.maintenance_whitelist ENABLE ROW LEVEL SECURITY;

--
-- Name: message_reactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;

--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: moderator_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.moderator_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: moderator_presets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.moderator_presets ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_bounties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_bounties ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_config ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_tester_stats; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_tester_stats ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_tickets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_tickets ENABLE ROW LEVEL SECURITY;

--
-- Name: qa_votes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.qa_votes ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_ad_placements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_ad_placements ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_ad_placements radio_ads_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_ads_read ON public.radio_ad_placements FOR SELECT USING (true);


--
-- Name: radio_bids; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_bids ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_bids radio_bids_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_bids_read ON public.radio_bids FOR SELECT USING (true);


--
-- Name: radio_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_config ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_config radio_config_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_config_read ON public.radio_config FOR SELECT USING (true);


--
-- Name: radio_listens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_listens ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_listens radio_listens_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_listens_own ON public.radio_listens FOR SELECT USING (true);


--
-- Name: radio_predictions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_predictions ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_predictions radio_predictions_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_predictions_own ON public.radio_predictions FOR SELECT USING (true);


--
-- Name: radio_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_queue radio_queue_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_queue_read ON public.radio_queue FOR SELECT USING (true);


--
-- Name: radio_slots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_slots ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_slots radio_slots_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_slots_read ON public.radio_slots FOR SELECT USING (true);


--
-- Name: reputation_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reputation_events ENABLE ROW LEVEL SECURITY;

--
-- Name: reputation_events reputation_events_own_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reputation_events_own_read ON public.reputation_events FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: reputation_tiers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reputation_tiers ENABLE ROW LEVEL SECURITY;

--
-- Name: reputation_tiers reputation_tiers_public_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reputation_tiers_public_read ON public.reputation_tiers FOR SELECT USING (true);


--
-- Name: role_change_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_change_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: role_invitation_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_invitation_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: role_invitations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_invitations ENABLE ROW LEVEL SECURITY;

--
-- Name: maintenance_whitelist superadmin_delete_whitelist; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY superadmin_delete_whitelist ON public.maintenance_whitelist FOR DELETE USING (public.is_admin(auth.uid()));


--
-- Name: maintenance_whitelist superadmin_insert_whitelist; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY superadmin_insert_whitelist ON public.maintenance_whitelist FOR INSERT WITH CHECK (public.is_super_admin((current_setting('request.jwt.claim.sub'::text, true))::uuid));


--
-- Name: templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;

--
-- Name: track_bookmarks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.track_bookmarks ENABLE ROW LEVEL SECURITY;

--
-- Name: track_feed_scores; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.track_feed_scores ENABLE ROW LEVEL SECURITY;

--
-- Name: track_likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.track_likes ENABLE ROW LEVEL SECURITY;

--
-- Name: track_quality_scores; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.track_quality_scores ENABLE ROW LEVEL SECURITY;

--
-- Name: track_reactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.track_reactions ENABLE ROW LEVEL SECURITY;

--
-- Name: track_reactions track_reactions_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY track_reactions_delete ON public.track_reactions FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: track_reactions track_reactions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY track_reactions_insert ON public.track_reactions FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: track_reactions track_reactions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY track_reactions_select ON public.track_reactions FOR SELECT USING (true);


--
-- Name: tracks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tracks ENABLE ROW LEVEL SECURITY;

--
-- Name: user_achievements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;

--
-- Name: user_achievements user_achievements_public_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_achievements_public_read ON public.user_achievements FOR SELECT USING (true);


--
-- Name: user_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: verification_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: vocal_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vocal_types ENABLE ROW LEVEL SECURITY;

--
-- Name: xp_event_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.xp_event_config ENABLE ROW LEVEL SECURITY;

--
-- Name: xp_event_config xp_event_config_public_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY xp_event_config_public_read ON public.xp_event_config FOR SELECT USING (true);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO authenticated;


--
-- Name: FUNCTION gtrgm_in(cstring); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_in(cstring) TO authenticated;


--
-- Name: FUNCTION gtrgm_out(public.gtrgm); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_out(public.gtrgm) TO authenticated;


--
-- Name: FUNCTION accept_role_invitation(_invitation_id uuid, _accept boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.accept_role_invitation(_invitation_id uuid, _accept boolean) TO authenticated;


--
-- Name: FUNCTION add_user_credits(p_user_id uuid, p_amount integer, p_reason text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.add_user_credits(p_user_id uuid, p_amount integer, p_reason text) TO authenticated;


--
-- Name: FUNCTION admin_add_xp(p_user_id uuid, p_xp_amount integer, p_reason text, p_reputation_amount integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_add_xp(p_user_id uuid, p_xp_amount integer, p_reason text, p_reputation_amount integer) TO authenticated;


--
-- Name: FUNCTION armor(bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.armor(bytea) TO authenticated;


--
-- Name: FUNCTION armor(bytea, text[], text[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.armor(bytea, text[], text[]) TO authenticated;


--
-- Name: FUNCTION award_contest_prize(_winner_id uuid, _contest_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.award_contest_prize(_winner_id uuid, _contest_id uuid) TO authenticated;


--
-- Name: FUNCTION award_xp(p_user_id uuid, p_event_type text, p_source_type text, p_source_id uuid, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.award_xp(p_user_id uuid, p_event_type text, p_source_type text, p_source_id uuid, p_metadata jsonb) TO authenticated;


--
-- Name: FUNCTION block_user(p_user_id uuid, p_reason text, p_blocked_by uuid, p_duration text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.block_user(p_user_id uuid, p_reason text, p_blocked_by uuid, p_duration text) TO authenticated;


--
-- Name: FUNCTION calculate_track_quality(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.calculate_track_quality(p_track_id uuid) TO authenticated;


--
-- Name: FUNCTION check_achievements_after_finalize(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_achievements_after_finalize() TO authenticated;


--
-- Name: FUNCTION check_contest_achievements(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_contest_achievements(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION check_user_achievements(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_user_achievements(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION cleanup_old_logs(p_days integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.cleanup_old_logs(p_days integer) TO authenticated;


--
-- Name: FUNCTION close_admin_conversation(p_conversation_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.close_admin_conversation(p_conversation_id uuid) TO authenticated;


--
-- Name: FUNCTION close_voting_topic_on_rejection(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.close_voting_topic_on_rejection(p_track_id uuid) TO authenticated;


--
-- Name: FUNCTION crypt(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.crypt(text, text) TO authenticated;


--
-- Name: FUNCTION dearmor(text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.dearmor(text) TO authenticated;


--
-- Name: FUNCTION decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.decrypt(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION decrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.decrypt_iv(bytea, bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION deduct_user_xp(p_user_id uuid, p_amount integer, p_reason text, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.deduct_user_xp(p_user_id uuid, p_amount integer, p_reason text, p_metadata jsonb) TO authenticated;


--
-- Name: FUNCTION delete_forum_topic_cascade(p_topic_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.delete_forum_topic_cascade(p_topic_id uuid) TO authenticated;


--
-- Name: FUNCTION digest(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.digest(bytea, text) TO authenticated;


--
-- Name: FUNCTION digest(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.digest(text, text) TO authenticated;


--
-- Name: FUNCTION encrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.encrypt(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION encrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.encrypt_iv(bytea, bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION finalize_contest(p_contest_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.finalize_contest(p_contest_id uuid) TO authenticated;


--
-- Name: FUNCTION finalize_contest_winners(p_contest_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.finalize_contest_winners(p_contest_id uuid) TO authenticated;


--
-- Name: FUNCTION find_similar_qa_tickets(p_title text, p_category text, p_threshold numeric, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.find_similar_qa_tickets(p_title text, p_category text, p_threshold numeric, p_limit integer) TO authenticated;


--
-- Name: FUNCTION forum_authority_leaderboard(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_authority_leaderboard(p_limit integer) TO authenticated;


--
-- Name: FUNCTION forum_boost_topic(p_topic_id uuid, p_boost_type text, p_duration_hours integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_boost_topic(p_topic_id uuid, p_boost_type text, p_duration_hours integer) TO authenticated;


--
-- Name: FUNCTION forum_calculate_content_quality(p_content_type text, p_content_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_calculate_content_quality(p_content_type text, p_content_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_find_similar_topics(p_title text, p_category_id uuid, p_threshold numeric, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_find_similar_topics(p_title text, p_category_id uuid, p_threshold numeric, p_limit integer) TO authenticated;


--
-- Name: FUNCTION forum_get_hub_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_get_hub_stats() TO authenticated;


--
-- Name: FUNCTION forum_get_leaderboard(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_get_leaderboard(p_limit integer) TO authenticated;


--
-- Name: FUNCTION forum_get_user_profile(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_get_user_profile(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_increment_topic_views(p_topic_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_increment_topic_views(p_topic_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_mark_read(p_user_id uuid, p_topic_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_mark_read(p_user_id uuid, p_topic_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_mark_solution(p_post_id uuid, p_topic_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_moderate_promo(p_promo_id uuid, p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_moderate_promo(p_promo_id uuid, p_action text) TO authenticated;


--
-- Name: FUNCTION forum_recalculate_authority(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_recalculate_authority(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION forum_search(p_query text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_search(p_query text, p_limit integer) TO authenticated;


--
-- Name: FUNCTION forum_update_category_on_topic(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_update_category_on_topic() TO authenticated;


--
-- Name: FUNCTION forum_update_topic_on_post(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_update_topic_on_post() TO authenticated;


--
-- Name: FUNCTION forum_update_user_stats_on_post(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_update_user_stats_on_post() TO authenticated;


--
-- Name: FUNCTION forum_update_user_stats_on_topic(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_update_user_stats_on_topic() TO authenticated;


--
-- Name: FUNCTION forum_user_is_banned(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.forum_user_is_banned(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION gen_random_bytes(integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_random_bytes(integer) TO authenticated;


--
-- Name: FUNCTION gen_random_uuid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_random_uuid() TO authenticated;


--
-- Name: FUNCTION gen_salt(text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_salt(text) TO authenticated;


--
-- Name: FUNCTION gen_salt(text, integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_salt(text, integer) TO authenticated;


--
-- Name: FUNCTION generate_share_token(p_track_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.generate_share_token(p_track_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_ad_for_slot(p_slot_key text, p_user_id uuid, p_device_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_ad_for_slot(p_slot_key text, p_user_id uuid, p_device_type text) TO authenticated;


--
-- Name: TABLE tracks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tracks TO authenticated;


--
-- Name: FUNCTION get_boosted_tracks(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_boosted_tracks(p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_contest_leaderboard(p_type text, p_season_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_contest_leaderboard(p_type text, p_season_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_creator_earnings_profile(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_creator_earnings_profile(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_economy_health(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_economy_health() TO authenticated;


--
-- Name: FUNCTION get_feed_tracks_with_profiles(p_user_id uuid, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_feed_tracks_with_profiles(p_user_id uuid, p_limit integer, p_offset integer) TO authenticated;


--
-- Name: FUNCTION get_feed_tracks_with_profiles(p_user_id uuid, p_tab text, p_genre_id uuid, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_feed_tracks_with_profiles(p_user_id uuid, p_tab text, p_genre_id uuid, p_limit integer, p_offset integer) TO authenticated;


--
-- Name: FUNCTION get_or_create_referral_code(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_or_create_referral_code(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_qa_dashboard_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_qa_dashboard_stats() TO authenticated;


--
-- Name: FUNCTION get_qa_leaderboard(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_qa_leaderboard(p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_radio_smart_queue(p_user_id uuid, p_genre_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_smart_queue(p_user_id uuid, p_genre_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_radio_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_stats() TO authenticated;


--
-- Name: FUNCTION get_reputation_leaderboard(p_type text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_reputation_leaderboard(p_type text, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_reputation_profile(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_reputation_profile(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_smart_feed(p_user_id uuid, p_stream text, p_genre_id uuid, p_offset integer, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_smart_feed(p_user_id uuid, p_stream text, p_genre_id uuid, p_offset integer, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_track_by_share_token(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_by_share_token(p_token text) TO authenticated;


--
-- Name: FUNCTION get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_track_prompt_info(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_prompt_info(p_track_id uuid) TO authenticated;


--
-- Name: FUNCTION get_user_block_info(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_block_info(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_user_contest_rating(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_contest_rating(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_user_emails(p_user_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_emails(p_user_ids uuid[]) TO authenticated;


--
-- Name: FUNCTION get_user_role(_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_role(_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_user_stats(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_stats(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_user_vote_weight(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_vote_weight(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION gin_extract_query_trgm(text, internal, smallint, internal, internal, internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gin_extract_query_trgm(text, internal, smallint, internal, internal, internal, internal) TO authenticated;


--
-- Name: FUNCTION gin_extract_value_trgm(text, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gin_extract_value_trgm(text, internal) TO authenticated;


--
-- Name: FUNCTION gin_trgm_consistent(internal, smallint, text, integer, internal, internal, internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gin_trgm_consistent(internal, smallint, text, integer, internal, internal, internal, internal) TO authenticated;


--
-- Name: FUNCTION gin_trgm_triconsistent(internal, smallint, text, integer, internal, internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gin_trgm_triconsistent(internal, smallint, text, integer, internal, internal, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_compress(internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_compress(internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_consistent(internal, text, smallint, oid, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_consistent(internal, text, smallint, oid, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_decompress(internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_decompress(internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_distance(internal, text, smallint, oid, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_distance(internal, text, smallint, oid, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_options(internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_options(internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_penalty(internal, internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_penalty(internal, internal, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_picksplit(internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_picksplit(internal, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_same(public.gtrgm, public.gtrgm, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_same(public.gtrgm, public.gtrgm, internal) TO authenticated;


--
-- Name: FUNCTION gtrgm_union(internal, internal); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gtrgm_union(internal, internal) TO authenticated;


--
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_user() TO authenticated;


--
-- Name: FUNCTION has_permission(_user_id uuid, _category_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_permission(_user_id uuid, _category_key text) TO authenticated;


--
-- Name: FUNCTION has_purchased_item(p_item_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_purchased_item(p_item_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION has_purchased_prompt(p_prompt_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_purchased_prompt(p_prompt_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION has_role(_user_id uuid, _role public.app_role); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_role(_user_id uuid, _role public.app_role) TO authenticated;


--
-- Name: FUNCTION hide_contest_comment(p_comment_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hide_contest_comment(p_comment_id uuid) TO authenticated;


--
-- Name: FUNCTION hide_track_comment(p_comment_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hide_track_comment(p_comment_id uuid) TO authenticated;


--
-- Name: FUNCTION hmac(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hmac(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION hmac(text, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hmac(text, text, text) TO authenticated;


--
-- Name: FUNCTION increment_prompt_downloads(p_prompt_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.increment_prompt_downloads(p_prompt_id uuid) TO authenticated;


--
-- Name: FUNCTION is_admin(_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin(_user_id uuid) TO authenticated;


--
-- Name: FUNCTION is_participant_in_conversation(p_user_id uuid, p_conversation_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_participant_in_conversation(p_user_id uuid, p_conversation_id uuid) TO authenticated;


--
-- Name: FUNCTION is_super_admin(_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_super_admin(_user_id uuid) TO authenticated;


--
-- Name: FUNCTION is_user_blocked(_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_user_blocked(_user_id uuid) TO authenticated;


--
-- Name: FUNCTION notify_table_change(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.notify_table_change() TO authenticated;


--
-- Name: FUNCTION pgp_armor_headers(text, OUT key text, OUT value text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_armor_headers(text, OUT key text, OUT value text) TO authenticated;


--
-- Name: FUNCTION pgp_key_id(bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_key_id(bytea) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text, text) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text, text) TO authenticated;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea) TO authenticated;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea) TO authenticated;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text) TO authenticated;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text, text) TO authenticated;


--
-- Name: FUNCTION pin_comment(p_comment_id uuid, p_pinned boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pin_comment(p_comment_id uuid, p_pinned boolean) TO authenticated;


--
-- Name: FUNCTION prevent_self_vote(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.prevent_self_vote() TO authenticated;


--
-- Name: FUNCTION process_beat_purchase(p_beat_id uuid, p_buyer_id uuid, p_license_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_beat_purchase(p_beat_id uuid, p_buyer_id uuid, p_license_type text) TO authenticated;


--
-- Name: FUNCTION process_contest_lifecycle(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_contest_lifecycle() TO authenticated;


--
-- Name: FUNCTION process_prompt_purchase(p_prompt_id uuid, p_buyer_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_prompt_purchase(p_prompt_id uuid, p_buyer_id uuid) TO authenticated;


--
-- Name: FUNCTION process_store_item_purchase(p_item_id uuid, p_buyer_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_store_item_purchase(p_item_id uuid, p_buyer_id uuid) TO authenticated;


--
-- Name: FUNCTION protect_super_admin_role(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_super_admin_role() TO authenticated;


--
-- Name: FUNCTION protect_superadmin_auth_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_superadmin_auth_delete() TO authenticated;


--
-- Name: FUNCTION protect_superadmin_auth_update(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_superadmin_auth_update() TO authenticated;


--
-- Name: FUNCTION protect_superadmin_profile_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_superadmin_profile_delete() TO authenticated;


--
-- Name: FUNCTION protect_superadmin_profile_update(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_superadmin_profile_update() TO authenticated;


--
-- Name: FUNCTION protect_superadmin_role_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.protect_superadmin_role_delete() TO authenticated;


--
-- Name: FUNCTION purchase_ad_free(p_user_id uuid, p_days integer, p_cost integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.purchase_ad_free(p_user_id uuid, p_days integer, p_cost integer) TO authenticated;


--
-- Name: FUNCTION purchase_track_boost(p_track_id uuid, p_user_id uuid, p_duration_hours integer, p_cost integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.purchase_track_boost(p_track_id uuid, p_user_id uuid, p_duration_hours integer, p_cost integer) TO authenticated;


--
-- Name: FUNCTION qa_generate_ticket_number(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.qa_generate_ticket_number() TO authenticated;


--
-- Name: FUNCTION qa_recalculate_priority(p_ticket_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.qa_recalculate_priority(p_ticket_id uuid) TO authenticated;


--
-- Name: FUNCTION qa_update_tester_tier(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.qa_update_tester_tier(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION qa_update_timestamp(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.qa_update_timestamp() TO authenticated;


--
-- Name: FUNCTION radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text) TO authenticated;


--
-- Name: FUNCTION radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text) TO authenticated;


--
-- Name: FUNCTION radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount numeric) TO authenticated;


--
-- Name: FUNCTION radio_place_prediction(p_user_id uuid, p_track_id uuid, p_bet_amount numeric, p_predicted_hit boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_place_prediction(p_user_id uuid, p_track_id uuid, p_bet_amount numeric, p_predicted_hit boolean) TO authenticated;


--
-- Name: FUNCTION radio_resolve_predictions(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_resolve_predictions() TO authenticated;


--
-- Name: FUNCTION radio_skip_ad(p_user_id uuid, p_ad_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_skip_ad(p_user_id uuid, p_ad_id uuid) TO authenticated;


--
-- Name: FUNCTION recalculate_feed_scores(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.recalculate_feed_scores(p_track_id uuid) TO authenticated;


--
-- Name: FUNCTION record_ad_click(p_impression_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_ad_click(p_impression_id uuid) TO authenticated;


--
-- Name: FUNCTION record_ad_impression(p_campaign_id uuid, p_creative_id uuid, p_slot_key text, p_user_id uuid, p_device_type text, p_page_url text, p_session_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_ad_impression(p_campaign_id uuid, p_creative_id uuid, p_slot_key text, p_user_id uuid, p_device_type text, p_page_url text, p_session_id text) TO authenticated;


--
-- Name: FUNCTION resolve_track_voting(p_track_id uuid, p_result text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.resolve_track_voting(p_track_id uuid, p_result text) TO authenticated;


--
-- Name: FUNCTION revoke_share_token(p_track_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.revoke_share_token(p_track_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION safe_award_xp(p_user_id uuid, p_event_type text, p_source_type text, p_source_id uuid, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.safe_award_xp(p_user_id uuid, p_event_type text, p_source_type text, p_source_id uuid, p_metadata jsonb) TO authenticated;


--
-- Name: FUNCTION set_limit(real); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_limit(real) TO authenticated;


--
-- Name: FUNCTION show_limit(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.show_limit() TO authenticated;


--
-- Name: FUNCTION show_trgm(text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.show_trgm(text) TO authenticated;


--
-- Name: FUNCTION similarity(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.similarity(text, text) TO authenticated;


--
-- Name: FUNCTION similarity_dist(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.similarity_dist(text, text) TO authenticated;


--
-- Name: FUNCTION similarity_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.similarity_op(text, text) TO authenticated;


--
-- Name: FUNCTION strict_word_similarity(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.strict_word_similarity(text, text) TO authenticated;


--
-- Name: FUNCTION strict_word_similarity_commutator_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.strict_word_similarity_commutator_op(text, text) TO authenticated;


--
-- Name: FUNCTION strict_word_similarity_dist_commutator_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.strict_word_similarity_dist_commutator_op(text, text) TO authenticated;


--
-- Name: FUNCTION strict_word_similarity_dist_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.strict_word_similarity_dist_op(text, text) TO authenticated;


--
-- Name: FUNCTION strict_word_similarity_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.strict_word_similarity_op(text, text) TO authenticated;


--
-- Name: FUNCTION submit_contest_entry(p_contest_id uuid, p_track_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.submit_contest_entry(p_contest_id uuid, p_track_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION unblock_user(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.unblock_user(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION unhide_contest_comment(p_comment_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.unhide_contest_comment(p_comment_id uuid) TO authenticated;


--
-- Name: FUNCTION update_last_seen(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_last_seen(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION update_total_votes_received(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_total_votes_received() TO authenticated;


--
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_updated_at_column() TO authenticated;


--
-- Name: FUNCTION uuid_generate_v1(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_generate_v1() TO authenticated;


--
-- Name: FUNCTION uuid_generate_v1mc(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_generate_v1mc() TO authenticated;


--
-- Name: FUNCTION uuid_generate_v3(namespace uuid, name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_generate_v3(namespace uuid, name text) TO authenticated;


--
-- Name: FUNCTION uuid_generate_v4(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_generate_v4() TO authenticated;


--
-- Name: FUNCTION uuid_generate_v5(namespace uuid, name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_generate_v5(namespace uuid, name text) TO authenticated;


--
-- Name: FUNCTION uuid_nil(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_nil() TO authenticated;


--
-- Name: FUNCTION uuid_ns_dns(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_ns_dns() TO authenticated;


--
-- Name: FUNCTION uuid_ns_oid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_ns_oid() TO authenticated;


--
-- Name: FUNCTION uuid_ns_url(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_ns_url() TO authenticated;


--
-- Name: FUNCTION uuid_ns_x500(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.uuid_ns_x500() TO authenticated;


--
-- Name: FUNCTION vote_qa_ticket(p_ticket_id uuid, p_vote_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.vote_qa_ticket(p_ticket_id uuid, p_vote_type text) TO authenticated;


--
-- Name: FUNCTION withdraw_contest_entry(p_entry_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.withdraw_contest_entry(p_entry_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION word_similarity(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.word_similarity(text, text) TO authenticated;


--
-- Name: FUNCTION word_similarity_commutator_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.word_similarity_commutator_op(text, text) TO authenticated;


--
-- Name: FUNCTION word_similarity_dist_commutator_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.word_similarity_dist_commutator_op(text, text) TO authenticated;


--
-- Name: FUNCTION word_similarity_dist_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.word_similarity_dist_op(text, text) TO authenticated;


--
-- Name: FUNCTION word_similarity_op(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.word_similarity_op(text, text) TO authenticated;


--
-- Name: TABLE achievements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.achievements TO authenticated;


--
-- Name: TABLE ad_campaign_slots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_campaign_slots TO authenticated;


--
-- Name: TABLE ad_campaigns; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_campaigns TO authenticated;


--
-- Name: TABLE ad_creatives; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_creatives TO authenticated;


--
-- Name: TABLE ad_impressions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_impressions TO authenticated;


--
-- Name: TABLE ad_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_settings TO authenticated;


--
-- Name: TABLE ad_slots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_slots TO authenticated;


--
-- Name: TABLE ad_targeting; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ad_targeting TO authenticated;


--
-- Name: TABLE addon_services; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.addon_services TO authenticated;


--
-- Name: TABLE admin_announcements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.admin_announcements TO authenticated;


--
-- Name: TABLE admin_emails; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.admin_emails TO authenticated;


--
-- Name: TABLE ai_models; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ai_models TO authenticated;


--
-- Name: TABLE ai_provider_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ai_provider_settings TO authenticated;


--
-- Name: TABLE announcement_dismissals; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.announcement_dismissals TO authenticated;


--
-- Name: TABLE announcements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.announcements TO authenticated;


--
-- Name: TABLE api_keys; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.api_keys TO authenticated;


--
-- Name: TABLE artist_styles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.artist_styles TO authenticated;


--
-- Name: TABLE attribution_pools; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.attribution_pools TO authenticated;


--
-- Name: TABLE attribution_shares; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.attribution_shares TO authenticated;


--
-- Name: TABLE audio_separations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.audio_separations TO authenticated;


--
-- Name: TABLE balance_transactions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.balance_transactions TO authenticated;


--
-- Name: TABLE beat_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.beat_purchases TO authenticated;


--
-- Name: TABLE bug_reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bug_reports TO authenticated;


--
-- Name: TABLE challenges; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.challenges TO authenticated;


--
-- Name: TABLE comment_likes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comment_likes TO authenticated;


--
-- Name: TABLE comment_mentions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comment_mentions TO authenticated;


--
-- Name: TABLE comment_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comment_reactions TO authenticated;


--
-- Name: TABLE comment_reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comment_reports TO authenticated;


--
-- Name: TABLE comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comments TO authenticated;


--
-- Name: TABLE contest_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_achievements TO authenticated;


--
-- Name: TABLE contest_asset_downloads; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_asset_downloads TO authenticated;


--
-- Name: TABLE contest_comment_likes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_comment_likes TO authenticated;


--
-- Name: TABLE contest_entries; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_entries TO authenticated;


--
-- Name: TABLE contest_entry_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_entry_comments TO authenticated;


--
-- Name: TABLE contest_jury; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_jury TO authenticated;


--
-- Name: TABLE contest_jury_scores; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_jury_scores TO authenticated;


--
-- Name: TABLE contest_leagues; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_leagues TO authenticated;


--
-- Name: TABLE contest_ratings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_ratings TO authenticated;


--
-- Name: TABLE contest_seasons; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_seasons TO authenticated;


--
-- Name: TABLE contest_user_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_user_achievements TO authenticated;


--
-- Name: TABLE contest_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_votes TO authenticated;


--
-- Name: TABLE contest_winners; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contest_winners TO authenticated;


--
-- Name: TABLE contests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contests TO authenticated;


--
-- Name: TABLE conversation_participants; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.conversation_participants TO authenticated;


--
-- Name: TABLE conversations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.conversations TO authenticated;


--
-- Name: TABLE copyright_requests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.copyright_requests TO authenticated;


--
-- Name: TABLE creator_earnings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.creator_earnings TO authenticated;


--
-- Name: TABLE distribution_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.distribution_logs TO authenticated;


--
-- Name: TABLE distribution_requests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.distribution_requests TO authenticated;


--
-- Name: TABLE economy_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.economy_config TO authenticated;


--
-- Name: TABLE economy_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.economy_snapshots TO authenticated;


--
-- Name: TABLE email_templates; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.email_templates TO authenticated;


--
-- Name: TABLE email_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.email_verifications TO authenticated;


--
-- Name: TABLE error_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.error_logs TO authenticated;


--
-- Name: TABLE feature_trials; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.feature_trials TO authenticated;


--
-- Name: TABLE feed_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.feed_config TO authenticated;


--
-- Name: TABLE follows; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.follows TO authenticated;


--
-- Name: TABLE forum_activity_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_activity_log TO authenticated;


--
-- Name: TABLE forum_attachments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_attachments TO authenticated;


--
-- Name: TABLE forum_automod_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_automod_settings TO authenticated;


--
-- Name: TABLE forum_bookmarks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_bookmarks TO authenticated;


--
-- Name: TABLE forum_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_categories TO authenticated;


--
-- Name: TABLE forum_category_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_category_subscriptions TO authenticated;


--
-- Name: TABLE forum_citations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_citations TO authenticated;


--
-- Name: TABLE forum_content_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_content_purchases TO authenticated;


--
-- Name: TABLE forum_content_quality; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_content_quality TO authenticated;


--
-- Name: TABLE forum_drafts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_drafts TO authenticated;


--
-- Name: TABLE forum_hub_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_hub_config TO authenticated;


--
-- Name: TABLE forum_knowledge_articles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_knowledge_articles TO authenticated;


--
-- Name: TABLE forum_link_previews; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_link_previews TO authenticated;


--
-- Name: TABLE forum_mod_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_mod_logs TO authenticated;


--
-- Name: TABLE forum_poll_options; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_poll_options TO authenticated;


--
-- Name: TABLE forum_poll_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_poll_votes TO authenticated;


--
-- Name: TABLE forum_polls; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_polls TO authenticated;


--
-- Name: TABLE forum_post_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_post_reactions TO authenticated;


--
-- Name: TABLE forum_post_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_post_votes TO authenticated;


--
-- Name: TABLE forum_posts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_posts TO authenticated;


--
-- Name: TABLE forum_premium_content; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_premium_content TO authenticated;


--
-- Name: TABLE forum_promo_slots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_promo_slots TO authenticated;


--
-- Name: TABLE forum_read_status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_read_status TO authenticated;


--
-- Name: TABLE forum_reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_reports TO authenticated;


--
-- Name: TABLE forum_reputation_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_reputation_config TO authenticated;


--
-- Name: TABLE forum_reputation_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_reputation_log TO authenticated;


--
-- Name: TABLE forum_similar_topics; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_similar_topics TO authenticated;


--
-- Name: TABLE forum_staff_notes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_staff_notes TO authenticated;


--
-- Name: TABLE forum_tags; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_tags TO authenticated;


--
-- Name: TABLE forum_topic_boosts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topic_boosts TO authenticated;


--
-- Name: TABLE forum_topic_cluster_members; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topic_cluster_members TO authenticated;


--
-- Name: TABLE forum_topic_clusters; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topic_clusters TO authenticated;


--
-- Name: TABLE forum_topic_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topic_subscriptions TO authenticated;


--
-- Name: TABLE forum_topic_tags; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topic_tags TO authenticated;


--
-- Name: TABLE forum_topics; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_topics TO authenticated;


--
-- Name: TABLE forum_user_bans; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_user_bans TO authenticated;


--
-- Name: TABLE forum_user_ignores; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_user_ignores TO authenticated;


--
-- Name: TABLE forum_user_reads; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_user_reads TO authenticated;


--
-- Name: TABLE forum_user_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_user_stats TO authenticated;


--
-- Name: TABLE forum_warning_appeals; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_warning_appeals TO authenticated;


--
-- Name: TABLE forum_warning_points; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_warning_points TO authenticated;


--
-- Name: TABLE forum_warnings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.forum_warnings TO authenticated;


--
-- Name: TABLE gallery_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.gallery_items TO authenticated;


--
-- Name: TABLE gallery_likes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.gallery_likes TO authenticated;


--
-- Name: TABLE generated_lyrics; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.generated_lyrics TO authenticated;


--
-- Name: TABLE generation_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.generation_logs TO authenticated;


--
-- Name: TABLE generation_queue; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.generation_queue TO authenticated;


--
-- Name: TABLE genre_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.genre_categories TO authenticated;


--
-- Name: TABLE genres; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.genres TO authenticated;


--
-- Name: TABLE impersonation_action_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.impersonation_action_logs TO authenticated;


--
-- Name: TABLE internal_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.internal_votes TO authenticated;


--
-- Name: TABLE item_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.item_purchases TO authenticated;


--
-- Name: TABLE legal_documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.legal_documents TO authenticated;


--
-- Name: TABLE lyrics; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lyrics TO authenticated;


--
-- Name: TABLE lyrics_deposits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lyrics_deposits TO authenticated;


--
-- Name: TABLE lyrics_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lyrics_items TO authenticated;


--
-- Name: TABLE maintenance_whitelist; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.maintenance_whitelist TO authenticated;


--
-- Name: TABLE message_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.message_reactions TO authenticated;


--
-- Name: TABLE messages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.messages TO authenticated;


--
-- Name: TABLE moderator_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.moderator_permissions TO authenticated;


--
-- Name: TABLE moderator_presets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.moderator_presets TO authenticated;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.notifications TO authenticated;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payments TO authenticated;


--
-- Name: TABLE payout_requests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payout_requests TO authenticated;


--
-- Name: TABLE performance_alerts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.performance_alerts TO authenticated;


--
-- Name: TABLE permission_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_categories TO authenticated;


--
-- Name: TABLE personas; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.personas TO authenticated;


--
-- Name: TABLE playlist_tracks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.playlist_tracks TO authenticated;


--
-- Name: TABLE playlists; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.playlists TO authenticated;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.profiles TO authenticated;


--
-- Name: TABLE user_roles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_roles TO authenticated;


--
-- Name: TABLE profiles_public; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.profiles_public TO authenticated;


--
-- Name: TABLE promo_videos; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.promo_videos TO authenticated;


--
-- Name: TABLE prompt_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.prompt_purchases TO authenticated;


--
-- Name: TABLE prompts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.prompts TO authenticated;


--
-- Name: TABLE qa_bounties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_bounties TO authenticated;


--
-- Name: TABLE qa_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_comments TO authenticated;


--
-- Name: TABLE qa_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_config TO authenticated;


--
-- Name: TABLE qa_tester_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_tester_stats TO authenticated;


--
-- Name: TABLE qa_tickets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_tickets TO authenticated;


--
-- Name: TABLE qa_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.qa_votes TO authenticated;


--
-- Name: TABLE radio_ad_placements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_ad_placements TO authenticated;


--
-- Name: TABLE radio_bids; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_bids TO authenticated;


--
-- Name: TABLE radio_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_config TO authenticated;


--
-- Name: TABLE radio_listens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_listens TO authenticated;


--
-- Name: TABLE radio_predictions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_predictions TO authenticated;


--
-- Name: TABLE radio_queue; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_queue TO authenticated;


--
-- Name: TABLE radio_slots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.radio_slots TO authenticated;


--
-- Name: TABLE referral_codes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.referral_codes TO authenticated;


--
-- Name: TABLE referral_rewards; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.referral_rewards TO authenticated;


--
-- Name: TABLE referral_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.referral_settings TO authenticated;


--
-- Name: TABLE referral_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.referral_stats TO authenticated;


--
-- Name: TABLE referrals; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.referrals TO authenticated;


--
-- Name: TABLE reputation_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reputation_events TO authenticated;


--
-- Name: TABLE reputation_tiers; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reputation_tiers TO authenticated;


--
-- Name: TABLE role_change_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_change_logs TO authenticated;


--
-- Name: TABLE role_invitation_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_invitation_permissions TO authenticated;


--
-- Name: TABLE role_invitations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_invitations TO authenticated;


--
-- Name: TABLE security_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.security_audit_log TO authenticated;


--
-- Name: TABLE seller_earnings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.seller_earnings TO authenticated;


--
-- Name: TABLE settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.settings TO authenticated;


--
-- Name: TABLE store_beats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.store_beats TO authenticated;


--
-- Name: TABLE store_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.store_items TO authenticated;


--
-- Name: TABLE subscription_plans; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.subscription_plans TO authenticated;


--
-- Name: TABLE support_messages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.support_messages TO authenticated;


--
-- Name: TABLE support_tickets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.support_tickets TO authenticated;


--
-- Name: TABLE system_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.system_settings TO authenticated;


--
-- Name: TABLE templates; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.templates TO authenticated;


--
-- Name: TABLE ticket_messages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ticket_messages TO authenticated;


--
-- Name: TABLE track_addons; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_addons TO authenticated;


--
-- Name: TABLE track_bookmarks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_bookmarks TO authenticated;


--
-- Name: TABLE track_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_comments TO authenticated;


--
-- Name: TABLE track_daily_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_daily_stats TO authenticated;


--
-- Name: TABLE track_deposits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_deposits TO authenticated;


--
-- Name: TABLE track_feed_scores; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_feed_scores TO authenticated;


--
-- Name: TABLE track_health_reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_health_reports TO authenticated;


--
-- Name: TABLE track_likes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_likes TO authenticated;


--
-- Name: TABLE track_promotions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_promotions TO authenticated;


--
-- Name: TABLE track_quality_scores; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_quality_scores TO authenticated;


--
-- Name: TABLE track_reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_reports TO authenticated;


--
-- Name: TABLE track_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.track_votes TO authenticated;


--
-- Name: TABLE user_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_achievements TO authenticated;


--
-- Name: TABLE user_blocks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_blocks TO authenticated;


--
-- Name: TABLE user_challenges; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_challenges TO authenticated;


--
-- Name: TABLE user_follows; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_follows TO authenticated;


--
-- Name: TABLE user_prompts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_prompts TO authenticated;


--
-- Name: TABLE user_streaks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_streaks TO authenticated;


--
-- Name: TABLE user_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_subscriptions TO authenticated;


--
-- Name: TABLE verification_requests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.verification_requests TO authenticated;


--
-- Name: TABLE vocal_types; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vocal_types TO authenticated;


--
-- Name: TABLE xp_event_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.xp_event_config TO authenticated;


--
-- PostgreSQL database dump complete
--

\unrestrict s7DlPx6cBEd4MBtZoyctFpHkBFR5znzBStgy9ipFlf88eGdDIuAyIvcnkLS0bIc

