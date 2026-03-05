--
-- PostgreSQL database dump
--

\restrict VGnYHVuVeDI1rawLSZpuv4O7odj7hcIAg9tfveOc2s0bTv2JFwqO7ZExYCWsiNP

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
-- Name: admin_annul_vote(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_annul_vote(p_vote_id uuid, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  INSERT INTO vote_audit_log (vote_id, action, details)
  SELECT p_vote_id, 'revoke', jsonb_build_object('admin_annul', true, 'reason', p_reason);

  DELETE FROM weighted_votes WHERE id = p_vote_id;
END;
$$;


--
-- Name: admin_approve_purchase(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_approve_purchase(p_purchase_id uuid, p_admin_notes text DEFAULT ''::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_purchase RECORD;
  v_seller_balance_before INTEGER;
  v_seller_balance INTEGER;
  v_item_title TEXT;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
  INTO v_purchase
  FROM public.item_purchases ip
  JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RAISE EXCEPTION 'Purchase not found';
  END IF;

  IF v_purchase.admin_status != 'pending_review' THEN
    RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status;
  END IF;

  v_item_title := v_purchase.item_title;

  SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_purchase.seller_id FOR UPDATE;

  UPDATE public.profiles SET balance = balance + v_purchase.net_amount
  WHERE user_id = v_purchase.seller_id
  RETURNING balance INTO v_seller_balance;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    v_purchase.seller_id, v_purchase.net_amount, v_seller_balance_before, v_seller_balance,
    'sale_income',
    'Продажа (одобрено): ' || v_item_title,
    v_purchase.store_item_id, 'store_item'
  );

  UPDATE public.item_purchases
  SET admin_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
  WHERE id = p_purchase_id;

  UPDATE public.seller_earnings
  SET status = 'available'
  WHERE source_id = p_purchase_id;

  -- Transfer lyrics ownership to buyer (exclusive only)
  IF v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false) THEN
    UPDATE public.lyrics_items
    SET user_id = v_purchase.buyer_id, is_for_sale = false, is_active = false
    WHERE id = v_purchase.source_id;
  END IF;

  -- Notify seller
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.seller_id,
    'deal_approved',
    'Сделка одобрена',
    v_item_title || ' — ' || v_purchase.net_amount || ' ₽ зачислено',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );

  -- Notify buyer (especially for lyrics — now in "Мои тексты")
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.buyer_id,
    'deal_approved',
    'Покупка одобрена',
    v_item_title || ' — теперь в разделе «Мои тексты»',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;


--
-- Name: admin_end_voting_early(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_end_voting_early(p_track_id uuid, p_result text, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  RETURN public.resolve_track_voting(p_track_id, p_result);
END;
$$;


--
-- Name: admin_extend_promotion(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_extend_promotion(p_promotion_id uuid, p_hours integer DEFAULT 1) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_row RECORD;
  v_new_expires TIMESTAMP WITH TIME ZONE;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RETURN json_build_object('success', false, 'error', 'Доступ запрещён');
  END IF;
  
  SELECT * INTO v_row FROM public.track_promotions WHERE id = p_promotion_id;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Промо не найдено');
  END IF;
  
  v_new_expires := GREATEST(v_row.expires_at, now()) + (p_hours || ' hours')::INTERVAL;
  
  UPDATE public.track_promotions 
  SET expires_at = v_new_expires, is_active = true 
  WHERE id = p_promotion_id;
  
  RETURN json_build_object('success', true, 'expires_at', v_new_expires);
END;
$$;


--
-- Name: admin_get_active_votings(text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_active_votings(p_filter text DEFAULT NULL::text, p_sort text DEFAULT 'voting_ends_at'::text, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_offset INTEGER;
  v_tracks JSONB;
  v_total INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  v_offset := (p_page - 1) * p_per_page;

  SELECT COUNT(*) INTO v_total FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at > now();

  SELECT jsonb_agg(sub) INTO v_tracks FROM (
    SELECT t.id, t.title, t.cover_url, t.user_id, t.voting_ends_at,
      COALESCE(t.weighted_likes_sum, 0) AS weighted_likes,
      COALESCE(t.weighted_dislikes_sum, 0) AS weighted_dislikes,
      CASE WHEN (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)) > 0
        THEN (COALESCE(t.weighted_likes_sum, 0) / (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)))::NUMERIC
        ELSE 0 END AS approval_rate
    FROM tracks t
    WHERE t.moderation_status = 'voting' AND t.voting_ends_at > now()
    ORDER BY
      CASE WHEN p_sort = 'voting_ends_at' THEN t.voting_ends_at END ASC NULLS LAST,
      CASE WHEN p_sort = 'total_weight' THEN COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0) END DESC NULLS LAST,
      CASE WHEN p_sort = 'approval_rate' THEN COALESCE(t.weighted_likes_sum, 0) / NULLIF(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0), 0) END DESC NULLS LAST
    LIMIT p_per_page OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object('tracks', COALESCE(v_tracks, '[]'::jsonb), 'total', v_total);
END;
$$;


--
-- Name: admin_get_all_promotions(boolean, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_all_promotions(p_active_only boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, track_id uuid, track_title text, user_id uuid, username text, boost_type text, price_paid numeric, starts_at timestamp with time zone, expires_at timestamp with time zone, is_active boolean, impressions_count integer, clicks_count integer, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role IN ('admin', 'super_admin')) THEN
    RETURN;
  END IF;
  
  RETURN QUERY
  SELECT 
    tp.id,
    tp.track_id,
    t.title AS track_title,
    tp.user_id,
    p.username,
    tp.boost_type,
    COALESCE(tp.price_paid, 0)::NUMERIC AS price_paid,
    COALESCE(tp.starts_at, tp.created_at) AS starts_at,
    tp.expires_at,
    tp.is_active,
    COALESCE(tp.impressions_count, 0)::INTEGER AS impressions_count,
    COALESCE(tp.clicks_count, 0)::INTEGER AS clicks_count,
    tp.created_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  LEFT JOIN public.profiles p ON p.user_id = tp.user_id
  WHERE (NOT p_active_only OR (tp.is_active = true AND tp.expires_at > now()))
  ORDER BY tp.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- Name: admin_get_deal_blockchain_info(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_deal_blockchain_info(p_purchase_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_purchase RECORD;
  v_deposit RECORD;
  v_result JSONB;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.blockchain_tx_id, ip.item_type, ip.source_id
  INTO v_purchase
  FROM public.item_purchases ip
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RETURN NULL;
  END IF;

  v_result := jsonb_build_object(
    'tx_id', v_purchase.blockchain_tx_id,
    'timestamp', NULL
  );

  IF v_purchase.item_type = 'lyrics' AND v_purchase.source_id IS NOT NULL THEN
    SELECT ld.deposited_at, ld.timestamp_hash, ld.external_id
    INTO v_deposit
    FROM public.lyrics_deposits ld
    WHERE ld.lyrics_id = v_purchase.source_id
      AND ld.method = 'blockchain'
      AND ld.status = 'completed'
    ORDER BY ld.deposited_at DESC NULLS LAST
    LIMIT 1;

    IF v_deposit IS NOT NULL THEN
      v_result := jsonb_build_object(
        'tx_id', COALESCE(v_purchase.blockchain_tx_id, v_deposit.external_id, v_deposit.timestamp_hash),
        'timestamp', v_deposit.deposited_at,
        'timestamp_hash', v_deposit.timestamp_hash,
        'external_id', v_deposit.external_id
      );
    END IF;
  END IF;

  RETURN v_result;
END;
$$;


--
-- Name: admin_get_deal_content(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_deal_content(p_source_id uuid, p_item_type text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  IF p_item_type = 'lyrics' THEN
    SELECT jsonb_build_object(
      'title', li.title,
      'content', li.content,
      'description', li.description
    ) INTO v_result
    FROM public.lyrics_items li
    WHERE li.id = p_source_id;
  ELSIF p_item_type = 'prompt' THEN
    SELECT jsonb_build_object(
      'title', up.title,
      'content', COALESCE(up.lyrics, ''),
      'description', up.description
    ) INTO v_result
    FROM public.user_prompts up
    WHERE up.id = p_source_id;
  ELSE
    RETURN NULL;
  END IF;

  RETURN v_result;
END;
$$;


--
-- Name: admin_get_flagged_votes(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_flagged_votes(p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_offset INTEGER;
  v_rows JSONB;
  v_total INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  v_offset := (p_page - 1) * p_per_page;

  SELECT COUNT(*) INTO v_total FROM weighted_votes WHERE fraud_multiplier < 0.5;

  SELECT jsonb_agg(row_to_json(wv)) INTO v_rows
  FROM (
    SELECT id, track_id, user_id, vote_type, fraud_multiplier, created_at
    FROM weighted_votes
    WHERE fraud_multiplier < 0.5
    ORDER BY created_at DESC
    LIMIT p_per_page OFFSET v_offset
  ) wv;

  RETURN jsonb_build_object('votes', COALESCE(v_rows, '[]'::jsonb), 'total', v_total);
END;
$$;


--
-- Name: admin_get_voting_dashboard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_voting_dashboard() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_active_count INTEGER;
  v_votes_today INTEGER;
  v_flagged_count INTEGER;
  v_ending_soon INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  SELECT COUNT(*) INTO v_active_count FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at > now();
  SELECT COUNT(*) INTO v_votes_today FROM weighted_votes WHERE created_at > CURRENT_DATE;
  SELECT COUNT(*) INTO v_flagged_count FROM weighted_votes WHERE fraud_multiplier < 0.5;
  SELECT COUNT(*) INTO v_ending_soon FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at BETWEEN now() AND now() + interval '24 hours';

  RETURN jsonb_build_object(
    'active_count', v_active_count,
    'votes_today', v_votes_today,
    'flagged_count', v_flagged_count,
    'ending_soon', v_ending_soon
  );
END;
$$;


--
-- Name: admin_reject_purchase(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_reject_purchase(p_purchase_id uuid, p_admin_notes text DEFAULT ''::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_purchase RECORD;
  v_buyer_balance_before INTEGER;
  v_buyer_balance INTEGER;
  v_item_title TEXT;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.*, si.title AS item_title
  INTO v_purchase
  FROM public.item_purchases ip
  JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RAISE EXCEPTION 'Purchase not found';
  END IF;

  IF v_purchase.admin_status != 'pending_review' THEN
    RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status;
  END IF;

  v_item_title := v_purchase.item_title;

  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = v_purchase.buyer_id FOR UPDATE;

  UPDATE public.profiles SET balance = balance + v_purchase.price
  WHERE user_id = v_purchase.buyer_id
  RETURNING balance INTO v_buyer_balance;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    v_purchase.buyer_id, v_purchase.price, v_buyer_balance_before, v_buyer_balance,
    'refund',
    'Возврат: ' || v_item_title,
    v_purchase.store_item_id, 'store_item'
  );

  UPDATE public.item_purchases
  SET admin_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
  WHERE id = p_purchase_id;

  UPDATE public.seller_earnings
  SET status = 'rejected'
  WHERE source_id = p_purchase_id;

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.buyer_id,
    'deal_rejected',
    'Сделка отклонена',
    v_item_title || ' — ' || v_purchase.price || ' ₽ возвращено',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.seller_id,
    'deal_rejected',
    'Сделка отклонена',
    v_item_title || ' — ' || COALESCE(p_admin_notes, 'Администрация отклонила сделку'),
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;


--
-- Name: admin_review_flagged_votes(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_flagged_votes(p_track_id uuid) RETURNS TABLE(vote_id uuid, user_id uuid, vote_type text, final_weight numeric, fraud_multiplier numeric, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  RETURN QUERY
  SELECT wv.id, wv.user_id, wv.vote_type, wv.final_weight, wv.fraud_multiplier, wv.created_at
  FROM weighted_votes wv
  WHERE wv.track_id = p_track_id AND wv.fraud_multiplier < 0.5
  ORDER BY wv.fraud_multiplier ASC;
END;
$$;


--
-- Name: admin_stop_promotion(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_stop_promotion(p_promotion_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')
  ) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RETURN json_build_object('success', false, 'error', 'Доступ запрещён');
  END IF;

  UPDATE public.track_promotions
  SET is_active = false, status = 'expired'
  WHERE id = p_promotion_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Промо не найдено');
  END IF;

  RETURN json_build_object('success', true);
END;
$$;


--
-- Name: aggregate_votes_to_tracks(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.aggregate_votes_to_tracks() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_updated INTEGER := 0;
  v_n INTEGER := 0;
BEGIN
  WITH agg AS (
    SELECT
      wv.track_id,
      SUM(CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.final_weight ELSE 0 END) AS likes_sum,
      SUM(CASE WHEN wv.vote_type = 'dislike' THEN wv.final_weight ELSE 0 END) AS dislikes_sum,
      COUNT(*) FILTER (WHERE wv.vote_type IN ('like', 'superlike'))::INTEGER AS likes_count,
      COUNT(*) FILTER (WHERE wv.vote_type = 'dislike')::INTEGER AS dislikes_count
    FROM weighted_votes wv
    GROUP BY wv.track_id
  )
  UPDATE tracks t SET
    weighted_likes_sum = agg.likes_sum,
    weighted_dislikes_sum = agg.dislikes_sum,
    voting_likes_count = agg.likes_count,
    voting_dislikes_count = agg.dislikes_count
  FROM agg
  WHERE t.id = agg.track_id
  AND (
    COALESCE(t.weighted_likes_sum, 0) != agg.likes_sum
    OR COALESCE(t.weighted_dislikes_sum, 0) != agg.dislikes_sum
    OR COALESCE(t.voting_likes_count, 0) != agg.likes_count
    OR COALESCE(t.voting_dislikes_count, 0) != agg.dislikes_count
  );

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  -- Обнулить треки, у которых все голоса отозваны (нет строк в weighted_votes)
  UPDATE tracks t SET
    weighted_likes_sum = 0,
    weighted_dislikes_sum = 0,
    voting_likes_count = 0,
    voting_dislikes_count = 0
  WHERE (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)) > 0
  AND NOT EXISTS (SELECT 1 FROM weighted_votes wv WHERE wv.track_id = t.id);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_updated := v_updated + v_n;
  RETURN v_updated;
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
-- Name: assess_vote_fraud(uuid, uuid, text, inet); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assess_vote_fraud(p_user_id uuid, p_track_id uuid, p_fingerprint text DEFAULT NULL::text, p_ip inet DEFAULT NULL::inet) RETURNS numeric
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_multiplier NUMERIC := 1.0;
  v_track_owner UUID;
  v_account_age_hours NUMERIC;
  v_fingerprint_match BOOLEAN;
  v_ip_votes_count INTEGER;
  v_velocity_count INTEGER;
  v_same_author_count INTEGER;
  v_referral_connected BOOLEAN;
BEGIN
  SELECT EXTRACT(EPOCH FROM (now() - created_at)) / 3600 INTO v_account_age_hours
  FROM auth.users WHERE id = p_user_id;
  IF v_account_age_hours < 24 THEN
    v_multiplier := v_multiplier * 0.3;
  END IF;

  SELECT user_id INTO v_track_owner FROM tracks WHERE id = p_track_id;
  IF p_user_id = v_track_owner THEN
    RETURN 0.0;
  END IF;

  IF p_fingerprint IS NOT NULL AND length(p_fingerprint) > 0 THEN
    SELECT EXISTS(
      SELECT 1 FROM weighted_votes
      WHERE track_id = p_track_id AND fingerprint_hash = p_fingerprint AND user_id != p_user_id
    ) INTO v_fingerprint_match;
    IF v_fingerprint_match THEN
      RETURN 0.0;
    END IF;
  END IF;

  IF p_ip IS NOT NULL THEN
    SELECT COUNT(*) INTO v_ip_votes_count
    FROM weighted_votes
    WHERE track_id = p_track_id AND ip_address = p_ip;
    IF v_ip_votes_count >= 3 THEN
      v_multiplier := v_multiplier * 0.1;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_velocity_count
  FROM weighted_votes
  WHERE user_id = p_user_id AND created_at > now() - interval '5 minutes';
  IF v_velocity_count >= 10 THEN
    v_multiplier := v_multiplier * 0.2;
  END IF;

  SELECT COUNT(*) INTO v_same_author_count
  FROM weighted_votes wv
  JOIN tracks t ON t.id = wv.track_id
  WHERE wv.user_id = p_user_id AND t.user_id = v_track_owner;
  IF v_same_author_count >= 5 AND (SELECT COUNT(*) FROM weighted_votes WHERE user_id = p_user_id) <= v_same_author_count * 1.2 THEN
    v_multiplier := v_multiplier * 0.3;
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM referrals r
    WHERE ((r.referrer_id = p_user_id AND r.referred_id = v_track_owner)
       OR (r.referrer_id = v_track_owner AND r.referred_id = p_user_id))
    AND r.status = 'activated'
  ) INTO v_referral_connected;
  IF v_referral_connected THEN
    v_multiplier := v_multiplier * 0.5;
  END IF;

  RETURN GREATEST(0, LEAST(1, v_multiplier));
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
    xp_social = CASE WHEN v_config.category IN ('social', 'contest', 'general') THEN COALESCE(xp_social, 0) + v_xp ELSE COALESCE(xp_social, 0) END,
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
-- Name: calculate_chart_scores(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_chart_scores() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_chart_date DATE := CURRENT_DATE;
  v_chart_type TEXT;
BEGIN
  FOR v_chart_type IN SELECT unnest(ARRAY['daily', 'weekly', 'alltime'])
  LOOP
    -- Упрощённая формула: weighted_approval * log(voters+1)
    INSERT INTO chart_entries (track_id, position, previous_position, chart_score, chart_type, chart_date)
    SELECT
      t.id,
      row_number() OVER (ORDER BY
        (COALESCE(t.weighted_likes_sum, 0) / NULLIF(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0), 0))::NUMERIC
        * ln(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0) + 1)
        DESC NULLS LAST
      )::INTEGER,
      t.chart_position,
      (COALESCE(t.weighted_likes_sum, 0) / NULLIF(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0), 0))::NUMERIC
        * ln(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0) + 1),
      v_chart_type,
      v_chart_date
    FROM tracks t
    WHERE t.moderation_status IN ('approved', 'pending') AND t.is_public = true
    AND (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)) > 0
    ON CONFLICT (track_id, chart_type, chart_date) DO UPDATE SET
      position = EXCLUDED.position,
      previous_position = EXCLUDED.previous_position,
      chart_score = EXCLUDED.chart_score;
  END LOOP;
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
-- Name: can_write_during_maintenance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_write_during_maintenance() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT NOT is_maintenance_active()
      OR is_admin(auth.uid())
      OR is_maintenance_whitelisted(auth.uid())
$$;


--
-- Name: FUNCTION can_write_during_maintenance(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.can_write_during_maintenance() IS 'Returns true if user can write (maintenance off, or user is admin/whitelisted)';


--
-- Name: cast_radio_vote_for_arena(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cast_radio_vote_for_arena(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_track RECORD;
  v_fraud_multiplier NUMERIC := 1.0;
  v_raw_weight NUMERIC := 0.7;
  v_final_weight NUMERIC;
BEGIN
  -- Guard: трек существует и chart-eligible (approved/pending + is_public)
  SELECT * INTO v_track FROM tracks WHERE id = p_track_id;
  IF v_track IS NULL THEN
    RETURN FALSE;
  END IF;
  IF v_track.moderation_status NOT IN ('approved', 'pending') OR COALESCE(v_track.is_public, false) = false THEN
    RETURN FALSE;
  END IF;

  -- Guard: пользователь не голосовал уже за этот трек
  IF EXISTS (SELECT 1 FROM weighted_votes WHERE track_id = p_track_id AND user_id = p_user_id) THEN
    RETURN FALSE;
  END IF;

  -- Guard: не самоголосование
  IF v_track.user_id = p_user_id THEN
    RETURN FALSE;
  END IF;

  v_fraud_multiplier := assess_vote_fraud(p_user_id, p_track_id, NULL, NULL);
  v_final_weight := v_raw_weight * v_fraud_multiplier;

  INSERT INTO weighted_votes (
    track_id, user_id, vote_type, raw_weight, fraud_multiplier, combo_bonus, final_weight,
    fingerprint_hash, ip_address, context
  ) VALUES (
    p_track_id, p_user_id, 'like', v_raw_weight, v_fraud_multiplier, 0, v_final_weight,
    NULL, NULL,
    jsonb_build_object('source', 'radio', 'listen_duration', p_listen_duration_sec)
  );

  RETURN TRUE;
END;
$$;


--
-- Name: cast_weighted_vote(uuid, text, text, jsonb, inet); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cast_weighted_vote(p_track_id uuid, p_vote_type text, p_fingerprint text DEFAULT NULL::text, p_context jsonb DEFAULT NULL::jsonb, p_ip inet DEFAULT NULL::inet) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_track RECORD;
  v_raw_weight NUMERIC := 1.0;
  v_fraud_multiplier NUMERIC := 1.0;
  v_combo_bonus NUMERIC := 0.0;
  v_final_weight NUMERIC;
  v_vote_id UUID;
  v_combo_length INTEGER := 0;
  v_has_existing_vote BOOLEAN := false;
  v_voter_rank TEXT := 'scout';
  v_xp_earned INTEGER := 0;
  v_combo_window_hours INTEGER;
  v_existing_vote RECORD;
  v_superlike_cost INTEGER;
  v_daily_superlikes INTEGER;
  v_last_vote_at TIMESTAMPTZ;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT * INTO v_track FROM tracks WHERE id = p_track_id;
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;
  IF v_track.moderation_status != 'voting' OR v_track.voting_ends_at IS NULL OR v_track.voting_ends_at <= now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track is not in voting');
  END IF;

  IF v_track.user_id = v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'self_vote_blocked');
  END IF;

  IF p_vote_type NOT IN ('like', 'dislike', 'superlike') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid vote type');
  END IF;

  IF p_vote_type = 'superlike' THEN
    SELECT COALESCE((value)::integer, 50) INTO v_superlike_cost FROM settings WHERE key = 'voting_superlike_cost';
    SELECT COUNT(*) INTO v_daily_superlikes FROM weighted_votes
    WHERE user_id = v_user_id AND vote_type = 'superlike'
    AND created_at > (CURRENT_DATE at time zone 'UTC');
    IF v_daily_superlikes >= 1 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Superlike limit: 1 per day');
    END IF;
  END IF;

  SELECT * INTO v_existing_vote FROM weighted_votes WHERE track_id = p_track_id AND user_id = v_user_id;
  v_has_existing_vote := FOUND;
  IF v_has_existing_vote AND v_existing_vote.vote_type = p_vote_type THEN
    RETURN jsonb_build_object('success', true, 'unchanged', true, 'vote_id', v_existing_vote.id);
  END IF;

  SELECT COALESCE(fus.vote_weight, 1.0) INTO v_raw_weight
  FROM forum_user_stats fus WHERE fus.user_id = v_user_id;
  IF v_raw_weight IS NULL THEN
    SELECT COALESCE(rt.vote_weight, 1.0) INTO v_raw_weight
    FROM forum_user_stats fus
    LEFT JOIN reputation_tiers rt ON rt.min_xp <= COALESCE(fus.xp_total, 0)
    WHERE fus.user_id = v_user_id
    ORDER BY rt.level DESC NULLS LAST LIMIT 1;
  END IF;
  v_raw_weight := COALESCE(v_raw_weight, 1.0);

  IF p_vote_type = 'superlike' THEN
    v_raw_weight := v_raw_weight * 5.0;
  END IF;

  v_fraud_multiplier := assess_vote_fraud(v_user_id, p_track_id, p_fingerprint, p_ip);

  SELECT vc.combo_length, vc.last_vote_at INTO v_combo_length, v_last_vote_at
  FROM vote_combos vc WHERE vc.user_id = v_user_id AND vc.is_active = true
  ORDER BY vc.last_vote_at DESC LIMIT 1;

  v_combo_length := COALESCE(v_combo_length, 0);

  SELECT COALESCE((value)::integer, 36) INTO v_combo_window_hours FROM settings WHERE key = 'voting_combo_window_hours';
  IF v_combo_length > 0 AND v_last_vote_at < now() - (v_combo_window_hours || ' hours')::interval THEN
    v_combo_length := 0;
  END IF;

  v_combo_bonus := CASE
    WHEN v_combo_length >= 21 THEN 0.5
    WHEN v_combo_length >= 11 THEN 0.3
    WHEN v_combo_length >= 6 THEN 0.2
    WHEN v_combo_length >= 3 THEN 0.1
    ELSE 0.0
  END;

  v_final_weight := v_raw_weight * v_fraud_multiplier * (1 + v_combo_bonus);

  IF v_has_existing_vote THEN
    UPDATE weighted_votes SET
      vote_type = p_vote_type,
      raw_weight = v_raw_weight,
      fraud_multiplier = v_fraud_multiplier,
      combo_bonus = v_combo_bonus,
      final_weight = v_final_weight,
      fingerprint_hash = p_fingerprint,
      ip_address = p_ip,
      context = p_context
    WHERE id = v_existing_vote.id
    RETURNING id INTO v_vote_id;

    INSERT INTO vote_audit_log (vote_id, action, details)
    VALUES (v_vote_id, 'change', jsonb_build_object('old_type', v_existing_vote.vote_type, 'new_type', p_vote_type));
  ELSE
    INSERT INTO weighted_votes (track_id, user_id, vote_type, raw_weight, fraud_multiplier, combo_bonus, final_weight, fingerprint_hash, ip_address, context)
    VALUES (p_track_id, v_user_id, p_vote_type, v_raw_weight, v_fraud_multiplier, v_combo_bonus, v_final_weight, p_fingerprint, p_ip, p_context)
    RETURNING id INTO v_vote_id;

    INSERT INTO vote_audit_log (vote_id, action, details)
    VALUES (v_vote_id, 'cast', jsonb_build_object('final_weight', v_final_weight));

    IF v_fraud_multiplier < 0.5 THEN
      INSERT INTO vote_audit_log (vote_id, action, details)
      VALUES (v_vote_id, 'fraud_flag', jsonb_build_object('fraud_multiplier', v_fraud_multiplier));
    END IF;
  END IF;

  INSERT INTO voter_profiles (user_id, votes_cast_total, votes_cast_30d, last_vote_at, daily_votes_today, daily_votes_date, current_combo, best_combo, updated_at)
  VALUES (v_user_id, 1, 1, now(), 1, CURRENT_DATE, v_combo_length + 1, GREATEST(1, v_combo_length + 1), now())
  ON CONFLICT (user_id) DO UPDATE SET
    votes_cast_total = voter_profiles.votes_cast_total + 1,
    votes_cast_30d = voter_profiles.votes_cast_30d + 1,
    last_vote_at = now(),
    daily_votes_today = CASE WHEN voter_profiles.daily_votes_date = CURRENT_DATE THEN voter_profiles.daily_votes_today + 1 ELSE 1 END,
    daily_votes_date = CURRENT_DATE,
    current_combo = v_combo_length + 1,
    best_combo = GREATEST(voter_profiles.best_combo, v_combo_length + 1),
    updated_at = now();

  IF v_combo_length = 0 THEN
    UPDATE vote_combos SET is_active = false WHERE user_id = v_user_id AND is_active = true;
    INSERT INTO vote_combos (user_id, combo_length, bonus_earned, last_vote_at, is_active)
    VALUES (v_user_id, 1, v_combo_bonus, now(), true);
  ELSE
    UPDATE vote_combos SET combo_length = v_combo_length + 1, last_vote_at = now(), bonus_earned = bonus_earned + v_combo_bonus
    WHERE user_id = v_user_id AND is_active = true;
  END IF;

  -- Fixed: use 'settings' table instead of 'forum_automod_settings'
  SELECT COALESCE((value)::integer, 2) INTO v_xp_earned FROM settings WHERE key = 'xp_for_vote';
  v_xp_earned := fn_add_xp(v_user_id, v_xp_earned, 'social', false);

  SELECT voter_rank INTO v_voter_rank FROM voter_profiles WHERE user_id = v_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'vote_id', v_vote_id,
    'final_weight', v_final_weight,
    'combo_length', v_combo_length + 1,
    'xp_earned', v_xp_earned,
    'voter_rank', v_voter_rank
  );
END;
$$;


--
-- Name: cast_weighted_vote_debug(uuid, text, text, jsonb, inet); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cast_weighted_vote_debug(p_track_id uuid, p_vote_type text, p_fingerprint text DEFAULT NULL::text, p_context jsonb DEFAULT NULL::jsonb, p_ip inet DEFAULT NULL::inet) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_existing_vote RECORD;
  v_cnt INTEGER;
BEGIN
  v_user_id := auth.uid();
  RAISE NOTICE 'DEBUG: user_id = %', v_user_id;

  SELECT COUNT(*) INTO v_cnt FROM weighted_votes WHERE track_id = p_track_id AND user_id = v_user_id;
  RAISE NOTICE 'DEBUG: count matching votes = %', v_cnt;

  SELECT * INTO v_existing_vote FROM weighted_votes WHERE track_id = p_track_id AND user_id = v_user_id;
  IF v_existing_vote IS NOT NULL THEN
    RAISE NOTICE 'DEBUG: found existing vote id=%, type=%', v_existing_vote.id, v_existing_vote.vote_type;
    RETURN jsonb_build_object('found', true, 'id', v_existing_vote.id, 'type', v_existing_vote.vote_type);
  ELSE
    RAISE NOTICE 'DEBUG: NO existing vote found!';
    RETURN jsonb_build_object('found', false);
  END IF;
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
-- Name: check_maintenance_access(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_maintenance_access() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF is_maintenance_active()
     AND NOT is_admin(auth.uid())
     AND NOT is_maintenance_whitelisted(auth.uid())
  THEN
    RAISE EXCEPTION 'Service is under maintenance'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;


--
-- Name: FUNCTION check_maintenance_access(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.check_maintenance_access() IS 'Raises exception if maintenance is active and caller is not admin/whitelisted';


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
    SET search_path TO 'public'
    AS $$
DECLARE
  v_track RECORD;
  v_author_username TEXT;
  v_genre_name TEXT;
  v_topic_title TEXT;
  v_topic_content TEXT;
  v_slug TEXT;
  v_topic_id UUID;
  v_voting_category_id UUID;
  v_voting_ends TEXT;
BEGIN
  SELECT value::uuid INTO v_voting_category_id
  FROM settings WHERE key = 'forum_voting_category_id';

  IF v_voting_category_id IS NULL THEN
    RAISE EXCEPTION 'forum_voting_category_id not found in settings';
  END IF;

  SELECT id, title, user_id, cover_url, genre_id, voting_ends_at
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found: %', p_track_id;
  END IF;

  SELECT username INTO v_author_username
  FROM public.profiles
  WHERE user_id = v_track.user_id;

  v_author_username := COALESCE(v_author_username, 'Автор');

  IF v_track.genre_id IS NOT NULL THEN
    SELECT name_ru INTO v_genre_name
    FROM public.genres
    WHERE id = v_track.genre_id;
  END IF;

  IF v_track.voting_ends_at IS NOT NULL THEN
    v_voting_ends := to_char(v_track.voting_ends_at AT TIME ZONE 'Europe/Moscow', U&'DD.MM.YYYY \0432 HH24:MI') || U&' (\041C\0421\041A)';
  ELSE
    v_voting_ends := U&'\043D\0435 \0443\043A\0430\0437\0430\043D\043E';
  END IF;

  v_topic_title := U&'\+01F5F3\FE0F \0413\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \043D\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\044E: ' || v_track.title;

  v_topic_content := '## ' || U&'\+01F3B5' || ' ' || v_track.title || E'\n\n' ||
    U&'**\0418\0441\043F\043E\043B\043D\0438\0442\0435\043B\044C:** [' || v_author_username || '](/profile/' || v_track.user_id || ')' || E'\n';

  IF v_genre_name IS NOT NULL THEN
    v_topic_content := v_topic_content || U&'**\0416\0430\043D\0440:** ' || v_genre_name || E'\n';
  END IF;

  v_topic_content := v_topic_content || U&'**\0413\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0434\043E:** ' || v_voting_ends || E'\n\n' ||
    '---' || E'\n\n' ||
    U&'\042D\0442\043E\0442 \0442\0440\0435\043A \043F\0440\043E\0445\043E\0434\0438\0442 \0433\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0441\043E\043E\0431\0449\0435\0441\0442\0432\0430 \043F\0435\0440\0435\0434 \043E\0442\043F\0440\0430\0432\043A\043E\0439 \043D\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\044E. ' ||
    U&'\041F\043E\0441\043B\0443\0448\0430\0439\0442\0435 \0438 \043E\0446\0435\043D\0438\0442\0435 \2014 \0432\0430\0448 \0433\043E\043B\043E\0441 \0432\043B\0438\044F\0435\0442 \043D\0430 \0438\0442\043E\0433\043E\0432\043E\0435 \0440\0435\0448\0435\043D\0438\0435.' || E'\n\n' ||
    U&'\+01F447' || U&' **\0418\0441\043F\043E\043B\044C\0437\0443\0439\0442\0435 \0432\0438\0434\0436\0435\0442 \043D\0438\0436\0435, \0447\0442\043E\0431\044B \043F\0440\043E\0441\043B\0443\0448\0430\0442\044C \0442\0440\0435\043A \0438 \043F\0440\043E\0433\043E\043B\043E\0441\043E\0432\0430\0442\044C.**' || E'\n\n' ||
    '---' || E'\n\n' ||
    U&'\+01F4CB' || U&' [\041F\0440\0430\0432\0438\043B\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\0438](/distribution-requirements) \00B7 ' ||
    U&'\+01F3A7' || U&' [\041F\0440\043E\0444\0438\043B\044C \0438\0441\043F\043E\043B\043D\0438\0442\0435\043B\044F](/profile/' || v_track.user_id || ')';

  v_slug := lower(v_topic_title);
  v_slug := regexp_replace(v_slug, '[^a-zа-яё0-9\s]', '', 'gi');
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := left(v_slug, 80) || '-' || to_hex(extract(epoch from now())::bigint);

  INSERT INTO public.forum_topics (
    category_id, user_id, title, slug, content, excerpt, track_id, is_pinned, is_hidden
  ) VALUES (
    v_voting_category_id, p_moderator_id, v_topic_title, v_slug, v_topic_content,
    U&'\0422\0440\0435\043A \00AB' || v_track.title || U&'\00BB \043E\0442 ' || v_author_username || U&' \2014 \0433\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0441\043E\043E\0431\0449\0435\0441\0442\0432\0430 \043F\0435\0440\0435\0434 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\0435\0439.',
    p_track_id, true, false
  )
  RETURNING id INTO v_topic_id;

  UPDATE public.tracks SET forum_topic_id = v_topic_id WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;


--
-- Name: deactivate_expired_promotions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.deactivate_expired_promotions() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.track_promotions
  SET is_active = false, status = 'expired'
  WHERE is_active = true AND expires_at < now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


--
-- Name: debit_balance(uuid, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.debit_balance(p_user_id uuid, p_amount integer, p_description text DEFAULT 'debit'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_new_balance INTEGER;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR (v_caller != p_user_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  UPDATE public.profiles
    SET balance = balance - p_amount
    WHERE user_id = p_user_id AND balance >= p_amount
    RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, balance_before, balance_after)
  VALUES
    (p_user_id, -p_amount, 'debit', p_description, v_new_balance + p_amount, v_new_balance);

  RETURN v_new_balance;
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
-- Name: delete_forum_topic_cascade(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_forum_topic_cascade(p_topic_id uuid, p_moderator_id uuid, p_reason text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_category_id UUID;
  v_post_ids UUID[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = p_moderator_id
      AND role IN ('moderator', 'admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления темы';
  END IF;

  SELECT category_id INTO v_category_id FROM forum_topics WHERE id = p_topic_id;

  IF v_category_id IS NULL THEN
    RAISE EXCEPTION 'Тема не найдена';
  END IF;

  SELECT array_agg(id) INTO v_post_ids FROM forum_posts WHERE topic_id = p_topic_id;

  UPDATE tracks
  SET forum_topic_id = NULL,
      voting_result = NULL,
      voting_started_at = NULL,
      voting_ends_at = NULL,
      voting_likes_count = 0,
      voting_dislikes_count = 0,
      voting_type = NULL,
      moderation_status = CASE
        WHEN moderation_status = 'voting' THEN 'pending'
        ELSE moderation_status
      END
  WHERE forum_topic_id = p_topic_id;

  DELETE FROM forum_reports
    WHERE (target_type = 'topic' AND target_id = p_topic_id)
       OR (target_type = 'post'  AND target_id IN (
            SELECT id FROM forum_posts WHERE topic_id = p_topic_id
          ));

  IF v_post_ids IS NOT NULL THEN
    DELETE FROM forum_post_reactions WHERE post_id = ANY(v_post_ids);
    DELETE FROM forum_post_votes    WHERE post_id = ANY(v_post_ids);
    DELETE FROM forum_attachments   WHERE post_id = ANY(v_post_ids);
  END IF;

  DELETE FROM forum_bookmarks  WHERE topic_id = p_topic_id;
  DELETE FROM forum_drafts     WHERE topic_id = p_topic_id;
  DELETE FROM forum_topic_tags WHERE topic_id = p_topic_id;

  DELETE FROM forum_poll_votes   WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_poll_options WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_polls        WHERE topic_id = p_topic_id;

  DELETE FROM forum_posts WHERE topic_id = p_topic_id;

  DELETE FROM forum_topics WHERE id = p_topic_id;

  IF v_category_id IS NOT NULL THEN
    UPDATE forum_categories SET
      topics_count = (SELECT COUNT(*) FROM forum_topics WHERE category_id = v_category_id),
      posts_count  = (SELECT COUNT(*) FROM forum_posts fp JOIN forum_topics ft ON fp.topic_id = ft.id WHERE ft.category_id = v_category_id)
    WHERE id = v_category_id;
  END IF;

  INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
  VALUES (
    p_moderator_id,
    'delete_topic',
    'topic',
    p_topic_id,
    CASE WHEN p_reason IS NOT NULL
      THEN jsonb_build_object('reason', p_reason)
      ELSE NULL
    END
  );

  RETURN TRUE;
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
-- Name: fn_add_xp(uuid, numeric, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_add_xp(p_user_id uuid, p_amount numeric, p_category text DEFAULT 'forum'::text, p_admin_override boolean DEFAULT false) RETURNS integer
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
  v_effective_category TEXT;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;

  IF p_admin_override AND NOT public.is_admin(COALESCE(v_caller, '00000000-0000-0000-0000-000000000000'::uuid)) THEN
    RAISE EXCEPTION 'admin_override requires admin role';
  END IF;

  v_effective_category := CASE
    WHEN p_category IN ('forum', 'music', 'social') THEN p_category
    ELSE 'forum'
  END;

  INSERT INTO forum_user_stats (user_id)
    VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;

  UPDATE forum_user_stats
    SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
    WHERE user_id = p_user_id
      AND (xp_daily_date IS NULL OR xp_daily_date < CURRENT_DATE);

  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily
    FROM forum_user_stats WHERE user_id = p_user_id;

  IF p_amount > 0 THEN
    IF p_admin_override THEN
      v_actual_amount := p_amount::integer;
    ELSE
      v_actual_amount := LEAST(p_amount::integer, v_daily_cap - v_current_daily);
      IF v_actual_amount <= 0 THEN RETURN 0; END IF;
    END IF;
  ELSE
    v_actual_amount := p_amount::integer;
  END IF;

  UPDATE forum_user_stats SET
    xp_total = GREATEST(0, xp_total + v_actual_amount),
    xp_daily_earned = CASE WHEN v_actual_amount > 0 AND NOT p_admin_override
      THEN xp_daily_earned + v_actual_amount ELSE xp_daily_earned END,
    xp_forum = CASE WHEN v_effective_category = 'forum'
      THEN GREATEST(0, xp_forum + v_actual_amount) ELSE xp_forum END,
    xp_music = CASE WHEN v_effective_category = 'music'
      THEN GREATEST(0, xp_music + v_actual_amount) ELSE xp_music END,
    xp_social = CASE WHEN v_effective_category = 'social'
      THEN GREATEST(0, xp_social + v_actual_amount) ELSE xp_social END,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_total;

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

  v_event_type := CASE v_effective_category
    WHEN 'forum' THEN 'forum_xp'
    WHEN 'music' THEN 'music_xp'
    WHEN 'social' THEN 'social_xp'
    ELSE 'general_xp'
  END;

  IF v_actual_amount <> 0 THEN
    INSERT INTO public.reputation_events
      (user_id, event_type, xp_delta, reputation_delta, category, source_type, metadata)
    VALUES
      (p_user_id, v_event_type, v_actual_amount, 0, v_effective_category,
       CASE WHEN p_admin_override THEN 'admin' ELSE 'trigger' END,
       jsonb_build_object('via', 'fn_add_xp', 'admin_override', p_admin_override));
  END IF;

  RETURN COALESCE(v_actual_amount, 0);
END;
$$;


--
-- Name: fn_delete_store_items_on_source_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_delete_store_items_on_source_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  IF TG_TABLE_NAME = 'lyrics_items' THEN
    DELETE FROM public.store_items
     WHERE item_type = 'lyrics' AND source_id = OLD.id;
  ELSIF TG_TABLE_NAME = 'user_prompts' THEN
    DELETE FROM public.store_items
     WHERE item_type = 'prompt' AND source_id = OLD.id;
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: fn_xp_on_comment_like(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_xp_on_comment_like() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_author UUID;
BEGIN
  SELECT user_id INTO v_author FROM track_comments WHERE id = NEW.comment_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;

  IF EXISTS (
    SELECT 1 FROM reputation_events
    WHERE user_id = v_author AND event_type = 'social_xp'
      AND metadata->>'source_user' = NEW.user_id::text
      AND metadata->>'source_comment' = NEW.comment_id::text
      AND created_at > now() - interval '24 hours'
  ) THEN
    RETURN NEW;
  END IF;

  PERFORM fn_add_xp(v_author, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_comment_like'), 2), 'social');
  RETURN NEW;
END;
$$;


--
-- Name: fn_xp_on_follow(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_xp_on_follow() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.following_id = NEW.follower_id THEN RETURN NEW; END IF;

  IF EXISTS (
    SELECT 1 FROM reputation_events
    WHERE user_id = NEW.following_id AND event_type = 'social_xp'
      AND metadata->>'source_user' = NEW.follower_id::text
      AND metadata->>'source_type' = 'follow'
      AND created_at > now() - interval '24 hours'
  ) THEN
    RETURN NEW;
  END IF;

  PERFORM fn_add_xp(NEW.following_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_follower'), 3), 'social');
  RETURN NEW;
END;
$$;


--
-- Name: fn_xp_on_track_like(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_xp_on_track_like() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM tracks WHERE id = NEW.track_id;
  IF v_owner IS NULL OR v_owner = NEW.user_id THEN RETURN NEW; END IF;

  IF EXISTS (
    SELECT 1 FROM reputation_events
    WHERE user_id = v_owner AND event_type = 'music_xp'
      AND metadata->>'source_user' = NEW.user_id::text
      AND metadata->>'source_track' = NEW.track_id::text
      AND created_at > now() - interval '24 hours'
  ) THEN
    RETURN NEW;
  END IF;

  PERFORM fn_add_xp(v_owner, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_track_like'), 2), 'music');
  RETURN NEW;
END;
$$;


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
-- Name: generate_profile_slug(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_profile_slug() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  base_slug TEXT;
  final_slug TEXT;
  counter INT := 0;
BEGIN
  IF NEW.slug IS NOT NULL AND NEW.slug != '' THEN RETURN NEW; END IF;
  IF NEW.username IS NULL OR NEW.username = '' THEN RETURN NEW; END IF;
  base_slug := lower(regexp_replace(
    public.transliterate_ru(NEW.username), '[^a-z0-9]+', '-', 'g'
  ));
  base_slug := trim(both '-' from base_slug);
  IF base_slug = '' THEN RETURN NEW; END IF;
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.profiles WHERE slug = final_slug AND id != NEW.id) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter;
  END LOOP;
  NEW.slug := final_slug;
  RETURN NEW;
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
-- Name: generate_track_slug(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_track_slug() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  base_slug TEXT;
  artist TEXT;
  final_slug TEXT;
  counter INT := 0;
BEGIN
  IF NEW.slug IS NOT NULL AND NEW.slug != '' THEN RETURN NEW; END IF;
  SELECT username INTO artist FROM public.profiles WHERE user_id = NEW.user_id LIMIT 1;
  base_slug := lower(regexp_replace(
    public.transliterate_ru(coalesce(NEW.title, 'track')),
    '[^a-z0-9]+', '-', 'g'
  ));
  base_slug := trim(both '-' from base_slug);
  IF base_slug = '' THEN base_slug := 'track'; END IF;
  IF artist IS NOT NULL AND artist != '' THEN
    base_slug := base_slug || '-' || lower(regexp_replace(
      public.transliterate_ru(artist), '[^a-z0-9]+', '-', 'g'
    ));
    base_slug := trim(both '-' from base_slug);
  END IF;
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.tracks WHERE slug = final_slug AND id != NEW.id) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter;
  END LOOP;
  NEW.slug := final_slug;
  RETURN NEW;
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


--
-- Name: get_boosted_tracks(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_boosted_tracks(p_limit integer DEFAULT 5) RETURNS TABLE(track_id uuid, promotion_id uuid, boost_type text, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Деактивируем истекшие промо при каждом запросе
  PERFORM public.deactivate_expired_promotions();
  
  RETURN QUERY
  SELECT 
    tp.track_id,
    tp.id AS promotion_id,
    tp.boost_type,
    tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE 
    tp.is_active = true 
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
  ORDER BY 
    CASE tp.boost_type 
      WHEN 'top' THEN 1 
      WHEN 'premium' THEN 2 
      ELSE 3 
    END,
    tp.created_at DESC
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
-- Name: get_hero_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_hero_stats() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_total_tracks BIGINT;
  v_public_tracks BIGINT;
  v_total_users BIGINT;
  v_total_creators BIGINT;
BEGIN
  SELECT COUNT(*) INTO v_total_tracks FROM tracks WHERE status = 'completed';
  SELECT COUNT(*) INTO v_public_tracks FROM tracks WHERE status = 'completed' AND is_public = true;
  SELECT COUNT(*) INTO v_total_users FROM profiles;
  SELECT COUNT(DISTINCT user_id) INTO v_total_creators FROM tracks WHERE status = 'completed';

  RETURN jsonb_build_object(
    'totalTracks', COALESCE(v_total_tracks, 0),
    'publicTracks', COALESCE(v_public_tracks, 0),
    'totalUsers', COALESCE(v_total_users, 0),
    'totalCreators', COALESCE(v_total_creators, 0)
  );
END;
$$;


--
-- Name: get_l2e_admin_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_l2e_admin_stats() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_result JSONB;
  v_xp_today BIGINT := 0;
  v_listens_today BIGINT := 0;
  v_afk_verified_today BIGINT := 0;
  v_unique_listeners BIGINT := 0;
  v_active_sessions BIGINT := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listens') THEN
    SELECT COALESCE(SUM(xp_earned), 0) INTO v_xp_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COUNT(*) INTO v_listens_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COUNT(*) INTO v_afk_verified_today
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE AND is_afk_verified = true;
    SELECT COUNT(DISTINCT user_id) INTO v_unique_listeners
    FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listeners') THEN
    SELECT COUNT(*) INTO v_active_sessions
    FROM public.radio_listeners WHERE last_heartbeat > NOW() - INTERVAL '2 minutes';
  END IF;

  SELECT jsonb_build_object(
    'xp_awarded_today', v_xp_today,
    'listens_today', v_listens_today,
    'afk_verified_today', v_afk_verified_today,
    'unique_listeners_today', v_unique_listeners,
    'active_sessions_now', v_active_sessions,
    'avg_xp_per_listener', CASE WHEN v_unique_listeners > 0 THEN ROUND(v_xp_today::NUMERIC / v_unique_listeners, 1) ELSE 0 END
  ) INTO v_result;

  RETURN v_result;
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
-- Name: get_marketplace_items(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_marketplace_items(p_item_type text DEFAULT NULL::text) RETURNS TABLE(id uuid, seller_id uuid, item_type text, source_id uuid, title text, description text, price integer, license_type text, is_exclusive boolean, is_active boolean, sales_count integer, views_count integer, tags text[], genre_id uuid, preview_url text, cover_url text, created_at timestamp with time zone, updated_at timestamp with time zone, seller_username text, seller_avatar_url text, genre_name text, genre_name_ru text, deposit_method text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT
    si.id,
    si.seller_id,
    si.item_type,
    si.source_id,
    si.title,
    si.description,
    si.price,
    si.license_type,
    si.is_exclusive,
    si.is_active,
    si.sales_count,
    si.views_count,
    si.tags,
    si.genre_id,
    si.preview_url,
    si.cover_url,
    si.created_at,
    si.updated_at,
    p.username AS seller_username,
    p.avatar_url AS seller_avatar_url,
    g.name AS genre_name,
    g.name_ru AS genre_name_ru,
    CASE WHEN si.item_type = 'lyrics' THEN
      (SELECT ld.method
       FROM lyrics_deposits ld
       WHERE ld.lyrics_id = si.source_id
         AND ld.status = 'completed'
       ORDER BY CASE ld.method WHEN 'nris' THEN 0 ELSE 1 END,
                ld.deposited_at DESC NULLS LAST
       LIMIT 1)
    ELSE NULL
    END AS deposit_method
  FROM store_items si
  LEFT JOIN profiles p ON p.user_id = si.seller_id
  LEFT JOIN genres g ON g.id = si.genre_id
  WHERE si.is_active = true
    AND (p_item_type IS NULL OR p_item_type = 'all' OR si.item_type = p_item_type)
  ORDER BY si.sales_count DESC NULLS LAST
  LIMIT 100;
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
-- Name: get_prediction_votes(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_prediction_votes(p_track_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_hit INTEGER;
  v_no_hit INTEGER;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE predicted_hit = TRUE),
    COUNT(*) FILTER (WHERE predicted_hit = FALSE)
  INTO v_hit, v_no_hit
  FROM public.radio_predictions
  WHERE track_id = p_track_id AND status = 'pending';

  RETURN jsonb_build_object(
    'hit', COALESCE(v_hit, 0),
    'no_hit', COALESCE(v_no_hit, 0),
    'total', COALESCE(v_hit, 0) + COALESCE(v_no_hit, 0)
  );
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
-- Name: get_radio_listeners(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_listeners(p_limit integer DEFAULT 30) RETURNS TABLE(user_id uuid, username text, avatar_url text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    rl.user_id,
    p.username,
    p.avatar_url
  FROM public.radio_listeners rl
  JOIN public.profiles p ON p.user_id = rl.user_id
  WHERE rl.last_heartbeat > NOW() - INTERVAL '2 minutes'
  ORDER BY rl.last_heartbeat DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_radio_smart_queue(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_smart_queue(p_genre_id uuid DEFAULT NULL::uuid, p_mood text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(track_id uuid, title text, audio_url text, cover_url text, duration numeric, author_id uuid, author_username text, author_avatar text, author_tier text, author_xp integer, genre_name text, chance_score numeric, quality_component numeric, xp_component numeric, freshness_component numeric, discovery_component numeric, source text, is_boosted boolean, boost_type text, promotion_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_config JSONB;
  v_w_quality NUMERIC;
  v_w_xp NUMERIC;
  v_w_stake NUMERIC;
  v_w_freshness NUMERIC;
  v_w_discovery NUMERIC;
  v_min_quality NUMERIC;
  v_min_duration INTEGER;
  v_discovery_days INTEGER;
  v_discovery_mult NUMERIC;
  v_max_author_pct NUMERIC;
BEGIN
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'smart_stream';
  v_w_quality := COALESCE((v_config->>'W_quality')::NUMERIC, (v_config->>'w_quality')::NUMERIC, 0.35);
  v_w_xp := COALESCE((v_config->>'W_xp')::NUMERIC, (v_config->>'w_xp')::NUMERIC, 0.25);
  v_w_stake := COALESCE((v_config->>'W_stake')::NUMERIC, (v_config->>'w_stake')::NUMERIC, 0.20);
  v_w_freshness := COALESCE((v_config->>'W_freshness')::NUMERIC, (v_config->>'w_freshness')::NUMERIC, 0.15);
  v_w_discovery := COALESCE((v_config->>'W_discovery')::NUMERIC, (v_config->>'w_discovery')::NUMERIC, 0.05);
  v_min_quality := COALESCE((v_config->>'min_quality_score')::NUMERIC, 2.0);
  v_min_duration := COALESCE((v_config->>'min_duration_sec')::INTEGER, 30);
  v_discovery_days := COALESCE((v_config->>'discovery_boost_days')::INTEGER, 14);
  v_discovery_mult := COALESCE((v_config->>'discovery_boost_multiplier')::NUMERIC, 2.5);
  v_max_author_pct := COALESCE((v_config->>'max_author_share_percent')::NUMERIC, 15);

  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS track_id,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration::NUMERIC,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, p.subscription_type, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, p.xp, 0)::INTEGER AS author_xp,
      g.name_ru AS genre_name,
      LEAST(1.0, (COALESCE(t.likes_count, 0)::NUMERIC / GREATEST(1, COALESCE(t.plays_count, 1)))) AS quality_comp,
      LEAST(1.0, (COALESCE(p.xp, 0)::NUMERIC / 1000.0)) AS xp_comp,
      CASE
        WHEN t.created_at > NOW() - INTERVAL '1 day' THEN 1.0
        WHEN t.created_at > NOW() - INTERVAL '7 days' THEN 0.7
        WHEN t.created_at > NOW() - INTERVAL '30 days' THEN 0.4
        ELSE 0.2
      END AS freshness_comp,
      CASE
        WHEN t.created_at > NOW() - (v_discovery_days || ' days')::INTERVAL
             AND COALESCE(t.plays_count, 0) < 50
        THEN v_discovery_mult
        ELSE 1.0
      END AS discovery_mult,
      COALESCE(
        CASE tp.boost_type
          WHEN 'top' THEN 5.0
          WHEN 'premium' THEN 3.0
          WHEN 'standard' THEN 2.0
        END,
        1.0
      ) AS boost_mult,
      tp.boost_type AS promo_boost_type,
      tp.id AS promo_id,
      random() AS rng
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.track_promotions tp
      ON tp.track_id = t.id
      AND tp.status = 'active'
      AND tp.expires_at > NOW()
    WHERE t.status = 'completed'
      AND t.is_public = true
      AND COALESCE(t.duration, 0) >= v_min_duration
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
  )
  SELECT
    s.track_id,
    s.title,
    s.audio_url,
    s.cover_url,
    s.duration,
    s.author_id,
    s.author_username,
    s.author_avatar,
    s.author_tier,
    s.author_xp,
    s.genre_name,
    ROUND(((
      v_w_quality * s.quality_comp +
      v_w_xp * s.xp_comp +
      v_w_freshness * s.freshness_comp +
      v_w_discovery * LEAST(1.0, s.rng)
    ) * s.discovery_mult * s.boost_mult * (0.8 + 0.4 * s.rng))::NUMERIC, 4) AS chance_score,
    ROUND(s.quality_comp::NUMERIC, 4) AS quality_component,
    ROUND(s.xp_comp::NUMERIC, 4) AS xp_component,
    ROUND(s.freshness_comp::NUMERIC, 4) AS freshness_component,
    ROUND((v_w_discovery * s.rng)::NUMERIC, 4) AS discovery_component,
    CASE WHEN s.promo_id IS NOT NULL THEN 'promotion' ELSE 'algorithm' END AS source,
    (s.promo_id IS NOT NULL) AS is_boosted,
    s.promo_boost_type AS boost_type,
    s.promo_id AS promotion_id
  FROM scored s
  ORDER BY chance_score DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_radio_smart_queue(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_smart_queue(p_user_id uuid DEFAULT NULL::uuid, p_genre_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS TABLE(track_id uuid, title text, audio_url text, cover_url text, duration numeric, author_id uuid, author_username text, author_avatar text, author_tier text, author_xp integer, genre_name text, chance_score numeric, quality_component numeric, xp_component numeric, freshness_component numeric, discovery_component numeric, source text, is_boosted boolean, boost_type text, promotion_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_config JSONB;
  v_w_quality NUMERIC;
  v_w_xp NUMERIC;
  v_w_stake NUMERIC;
  v_w_freshness NUMERIC;
  v_w_discovery NUMERIC;
  v_min_quality NUMERIC;
  v_min_duration INTEGER;
  v_discovery_days INTEGER;
  v_discovery_mult NUMERIC;
  v_max_author_pct NUMERIC;
BEGIN
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'smart_stream';
  v_w_quality := COALESCE((v_config->>'W_quality')::NUMERIC, (v_config->>'w_quality')::NUMERIC, 0.35);
  v_w_xp := COALESCE((v_config->>'W_xp')::NUMERIC, (v_config->>'w_xp')::NUMERIC, 0.25);
  v_w_stake := COALESCE((v_config->>'W_stake')::NUMERIC, (v_config->>'w_stake')::NUMERIC, 0.20);
  v_w_freshness := COALESCE((v_config->>'W_freshness')::NUMERIC, (v_config->>'w_freshness')::NUMERIC, 0.15);
  v_w_discovery := COALESCE((v_config->>'W_discovery')::NUMERIC, (v_config->>'w_discovery')::NUMERIC, 0.05);
  v_min_quality := COALESCE((v_config->>'min_quality_score')::NUMERIC, 2.0);
  v_min_duration := COALESCE((v_config->>'min_duration_sec')::INTEGER, 30);
  v_discovery_days := COALESCE((v_config->>'discovery_boost_days')::INTEGER, 14);
  v_discovery_mult := COALESCE((v_config->>'discovery_boost_multiplier')::NUMERIC, 2.5);
  v_max_author_pct := COALESCE((v_config->>'max_author_share_percent')::NUMERIC, 15);

  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS track_id,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration::NUMERIC,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, p.subscription_type, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, COALESCE(p.xp, 0))::INTEGER AS author_xp,
      g.name_ru AS genre_name,
      LEAST(1.0, (COALESCE(t.likes_count, 0)::NUMERIC / GREATEST(1, COALESCE(t.plays_count, 1)))) AS quality_comp,
      LEAST(1.0, COALESCE(p.xp, 0)::NUMERIC / 1000.0) AS xp_comp,
      CASE
        WHEN t.created_at > NOW() - INTERVAL '1 day' THEN 1.0
        WHEN t.created_at > NOW() - INTERVAL '7 days' THEN 0.7
        WHEN t.created_at > NOW() - INTERVAL '30 days' THEN 0.4
        ELSE 0.2
      END AS freshness_comp,
      CASE
        WHEN t.created_at > NOW() - (v_discovery_days || ' days')::INTERVAL
             AND COALESCE(t.plays_count, 0) < 50
        THEN v_discovery_mult
        ELSE 1.0
      END AS discovery_mult,
      COALESCE(
        CASE tp.boost_type
          WHEN 'top' THEN 5.0
          WHEN 'premium' THEN 3.0
          WHEN 'standard' THEN 2.0
        END,
        1.0
      ) AS boost_mult,
      tp.boost_type AS promo_boost_type,
      tp.id AS promo_id,
      random() AS rng
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.track_promotions tp
      ON tp.track_id = t.id
      AND tp.is_active = true
      AND tp.expires_at > NOW()
    WHERE t.status = 'completed'
      AND t.is_public = true
      AND COALESCE(t.duration, 0) >= v_min_duration
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
  )
  SELECT
    s.track_id,
    s.title,
    s.audio_url,
    s.cover_url,
    s.duration,
    s.author_id,
    s.author_username,
    s.author_avatar,
    s.author_tier,
    s.author_xp,
    s.genre_name,
    ROUND((
      (
        v_w_quality * s.quality_comp +
        v_w_xp * s.xp_comp +
        v_w_freshness * s.freshness_comp +
        v_w_discovery * LEAST(1.0, s.rng)
      ) * s.discovery_mult * s.boost_mult * (0.8 + 0.4 * s.rng)
    )::numeric, 4) AS chance_score,
    s.quality_comp AS quality_component,
    s.xp_comp AS xp_component,
    s.freshness_comp AS freshness_component,
    s.discovery_mult AS discovery_component,
    CASE WHEN s.boost_mult > 1.0 THEN 'boost'::TEXT ELSE 'algorithm'::TEXT END AS source,
    (s.boost_mult > 1.0) AS is_boosted,
    s.promo_boost_type AS boost_type,
    s.promo_id AS promotion_id
  FROM scored s
  ORDER BY (v_w_quality * s.quality_comp + v_w_xp * s.xp_comp + v_w_freshness * s.freshness_comp + v_w_discovery * LEAST(1.0, s.rng)) * s.discovery_mult * s.boost_mult * (0.8 + 0.4 * s.rng) DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_radio_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_stats() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_result JSONB;
  v_listens_today BIGINT := 0;
  v_listens_total BIGINT := 0;
  v_unique_listeners_today BIGINT := 0;
  v_listeners_now BIGINT := 0;
  v_active_slots BIGINT := 0;
  v_pending_predictions BIGINT := 0;
  v_xp_awarded_today BIGINT := 0;
  v_revenue_today NUMERIC := 0;
  v_promotions_revenue NUMERIC := 0;
  v_tracks_played_today BIGINT := 0;
  v_top_tracks_today JSONB := '[]'::jsonb;
BEGIN
  -- Only query if radio_listens table exists
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listens') THEN
    SELECT COUNT(*) INTO v_listens_today FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COUNT(*) INTO v_listens_total FROM public.radio_listens;
    SELECT COUNT(DISTINCT user_id) INTO v_unique_listeners_today FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
    SELECT COALESCE(SUM(xp_earned), 0) INTO v_xp_awarded_today FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
  END IF;

  -- Only query if radio_listeners table exists (live presence)
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listeners') THEN
    SELECT COUNT(*) INTO v_listeners_now FROM public.radio_listeners WHERE last_heartbeat > NOW() - INTERVAL '2 minutes';
  END IF;

  -- Only query if radio_slots table exists
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_slots') THEN
    SELECT COUNT(*) INTO v_active_slots FROM public.radio_slots WHERE status IN ('open', 'bidding');
    
    -- Calculate revenue from auction slots
    SELECT COALESCE(SUM(winning_bid), 0) INTO v_revenue_today
    FROM public.radio_slots
    WHERE status = 'won' AND created_at >= CURRENT_DATE;
  END IF;

  -- Only query if radio_predictions table exists
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_predictions') THEN
    SELECT COUNT(*) INTO v_pending_predictions FROM public.radio_predictions WHERE status = 'pending';
  END IF;

  -- Only query if track_promotions table exists
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'track_promotions') THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_promotions_revenue
    FROM public.track_promotions
    WHERE created_at >= CURRENT_DATE AND is_active = true;
    
    v_revenue_today := v_revenue_today + v_promotions_revenue;
  END IF;

  -- Only query if radio_schedule table exists
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_schedule') THEN
    SELECT COUNT(*) INTO v_tracks_played_today FROM public.radio_schedule WHERE played_at >= CURRENT_DATE;
  END IF;
  
  -- Get top tracks today (requires both radio_listens and tracks)
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'radio_listens')
     AND EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tracks') THEN
    SELECT COALESCE(jsonb_agg(row_to_json(top)), '[]'::jsonb) INTO v_top_tracks_today
    FROM (
      SELECT rl.track_id, t.title, COUNT(*) AS plays
      FROM public.radio_listens rl
      JOIN public.tracks t ON t.id = rl.track_id
      WHERE rl.created_at >= CURRENT_DATE
      GROUP BY rl.track_id, t.title
      ORDER BY plays DESC
      LIMIT 5
    ) top;
  END IF;

  SELECT jsonb_build_object(
    'listens_today', v_listens_today,
    'listens_total', v_listens_total,
    'unique_listeners_today', v_unique_listeners_today,
    'listeners_now', v_listeners_now,
    'active_slots', v_active_slots,
    'pending_predictions', v_pending_predictions,
    'xp_awarded_today', v_xp_awarded_today,
    'revenue_today', v_revenue_today,
    'tracks_played_today', v_tracks_played_today,
    'top_tracks_today', v_top_tracks_today
  ) INTO v_result;

  RETURN v_result;
END;
$$;


--
-- Name: get_radio_xp_today(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_radio_xp_today(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_xp_today INTEGER;
BEGIN
  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  RETURN jsonb_build_object('xp_today', v_xp_today);
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
  v_decay JSONB;
  v_qg JSONB;
  v_following_ids UUID[];
  v_half_life NUMERIC;
BEGIN
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';
  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  IF p_stream = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM public.follows WHERE follower_id = p_user_id;
    IF v_following_ids IS NULL OR array_length(v_following_ids, 1) IS NULL THEN
      RETURN;
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
    p.username AS profile_username,
    p.avatar_url AS profile_avatar_url,
    p.display_name AS profile_display_name,
    COALESCE(fus.tier, 'newcomer') AS author_tier,
    rt.icon AS author_tier_icon,
    rt.color AS author_tier_color,
    COALESCE(p.is_verified, false) AS author_verified,
    g.name_ru AS genre_name_ru,
    COALESCE(fs.final_score, 0) AS feed_score,
    COALESCE(fs.velocity_24h, 0) AS feed_velocity,
    (bt.id IS NOT NULL AND bt.expires_at > now()) AS is_boosted,
    bt.expires_at AS boost_expires_at,
    COALESCE(tqs.quality_score, 0) AS quality_score
  FROM public.tracks t
  LEFT JOIN public.profiles p ON p.user_id = t.user_id
  LEFT JOIN public.genres g ON g.id = t.genre_id
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
  LEFT JOIN public.reputation_tiers rt ON rt.key = COALESCE(fus.tier, 'newcomer')
  LEFT JOIN public.track_feed_scores fs ON fs.track_id = t.id
  LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
  LEFT JOIN LATERAL (
    SELECT bt2.id, bt2.expires_at
    FROM public.track_promotions bt2
    WHERE bt2.track_id = t.id
      AND bt2.is_active = true
      AND bt2.expires_at > now()
    LIMIT 1
  ) bt ON true
  WHERE t.is_public = true
    AND t.status = 'completed'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE ub.user_id = t.user_id
        AND (ub.expires_at IS NULL OR ub.expires_at > now())
    )
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    AND (
      CASE p_stream
        WHEN 'following' THEN t.user_id = ANY(v_following_ids)
        WHEN 'trending' THEN
          COALESCE(t.plays_count, 0) >= COALESCE((v_qg->>'min_plays_for_trending')::int, 5)
          AND COALESCE(tqs.quality_score, 5) >= COALESCE((v_qg->>'min_score_for_trending')::numeric, 3.0)
        WHEN 'deep' THEN
          COALESCE(t.plays_count, 0) < 20
          AND t.created_at > now() - interval '14 days'
        ELSE true
      END
    )
    AND COALESCE(t.duration, 0) >= COALESCE((v_qg->>'min_duration_sec')::int, 30)
    AND COALESCE(fs.is_spam, false) = false
  ORDER BY
    CASE p_stream
      WHEN 'main' THEN
        COALESCE(fs.final_score, 0) *
        POWER(0.5, EXTRACT(EPOCH FROM (now() - t.created_at)) / 3600 / v_half_life)
        + CASE WHEN bt.id IS NOT NULL THEN 100 ELSE 0 END
      WHEN 'trending' THEN COALESCE(fs.velocity_24h, 0)
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'following' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'deep' THEN random() * 100 + COALESCE(tqs.quality_score, 5) * 10
      ELSE EXTRACT(EPOCH FROM t.created_at)
    END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
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
    weighted_likes_sum numeric DEFAULT 0,
    weighted_dislikes_sum numeric DEFAULT 0,
    chart_score numeric,
    chart_position integer,
    slug text,
    wav_expires_at timestamp with time zone,
    CONSTRAINT tracks_distribution_status_check CHECK ((distribution_status = ANY (ARRAY['none'::text, 'pending_moderation'::text, 'approved'::text, 'rejected'::text, 'pending_master'::text, 'processing'::text, 'completed'::text, 'voting'::text]))),
    CONSTRAINT tracks_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'completed'::text, 'failed'::text])))
);


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
-- Name: get_velocity_tracks(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_velocity_tracks(p_limit integer DEFAULT 5) RETURNS TABLE(track_id uuid, title text, cover_url text, audio_url text, user_id uuid, weighted_likes_now numeric, weighted_likes_1h_ago numeric, velocity_delta numeric, username text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  WITH current_stats AS (
    SELECT
      t.id AS track_id,
      COALESCE(t.weighted_likes_sum, 0)::NUMERIC AS weighted_likes_now
    FROM tracks t
    WHERE (t.weighted_likes_sum + COALESCE(t.weighted_dislikes_sum, 0)) > 0
  ),
  old_snapshots AS (
    SELECT DISTINCT ON (vs.track_id)
      vs.track_id,
      vs.weighted_likes AS weighted_likes_1h_ago
    FROM voting_snapshots vs
    WHERE vs.snapshot_at <= now() - interval '50 min'
      AND vs.snapshot_at >= now() - interval '2 hours'
    ORDER BY vs.track_id, vs.snapshot_at DESC
  ),
  combined AS (
    SELECT
      cs.track_id,
      cs.weighted_likes_now,
      COALESCE(os.weighted_likes_1h_ago, 0)::NUMERIC AS weighted_likes_1h_ago,
      (cs.weighted_likes_now - COALESCE(os.weighted_likes_1h_ago, 0))::NUMERIC AS velocity_delta
    FROM current_stats cs
    LEFT JOIN old_snapshots os ON os.track_id = cs.track_id
  )
  SELECT
    t.id AS track_id,
    t.title,
    t.cover_url,
    t.audio_url,
    t.user_id,
    c.weighted_likes_now,
    c.weighted_likes_1h_ago,
    c.velocity_delta,
    pp.username
  FROM combined c
  JOIN tracks t ON t.id = c.track_id
  LEFT JOIN profiles_public pp ON pp.user_id = t.user_id
  ORDER BY c.velocity_delta DESC NULLS LAST, c.weighted_likes_now DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_voter_profile(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_voter_profile(p_user_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid UUID;
  v_profile RECORD;
BEGIN
  v_uid := COALESCE(p_user_id, auth.uid());
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'Unauthorized');
  END IF;

  SELECT * INTO v_profile FROM voter_profiles WHERE user_id = v_uid;
  IF v_profile IS NULL THEN
    RETURN jsonb_build_object(
      'user_id', v_uid,
      'votes_cast_total', 0,
      'votes_cast_30d', 0,
      'correct_predictions', 0,
      'accuracy_rate', 0,
      'current_combo', 0,
      'best_combo', 0,
      'voter_rank', 'scout'
    );
  END IF;

  RETURN jsonb_build_object(
    'user_id', v_profile.user_id,
    'votes_cast_total', v_profile.votes_cast_total,
    'votes_cast_30d', v_profile.votes_cast_30d,
    'correct_predictions', v_profile.correct_predictions,
    'accuracy_rate', COALESCE(v_profile.accuracy_rate, 0),
    'current_combo', v_profile.current_combo,
    'best_combo', v_profile.best_combo,
    'last_vote_at', v_profile.last_vote_at,
    'voter_rank', v_profile.voter_rank
  );
END;
$$;


--
-- Name: get_voting_live_stats(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_voting_live_stats(p_track_ids uuid[]) RETURNS TABLE(track_id uuid, weighted_likes numeric, weighted_dislikes numeric, total_voters bigint, like_count bigint, dislike_count bigint, approval_rate numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    wv.track_id,
    COALESCE(SUM(CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.final_weight ELSE 0 END), 0)::NUMERIC AS weighted_likes,
    COALESCE(SUM(CASE WHEN wv.vote_type = 'dislike' THEN wv.final_weight ELSE 0 END), 0)::NUMERIC AS weighted_dislikes,
    COUNT(DISTINCT wv.user_id) AS total_voters,
    COUNT(DISTINCT CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.user_id END) AS like_count,
    COUNT(DISTINCT CASE WHEN wv.vote_type = 'dislike' THEN wv.user_id END) AS dislike_count,
    CASE
      WHEN SUM(wv.final_weight) > 0 THEN
        (SUM(CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.final_weight ELSE 0 END) / SUM(wv.final_weight))::NUMERIC
      ELSE 0::NUMERIC
    END AS approval_rate
  FROM weighted_votes wv
  WHERE wv.track_id = ANY(p_track_ids)
  GROUP BY wv.track_id;
END;
$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Block new registrations during maintenance (fail-closed)
  IF is_maintenance_active() THEN
    RAISE EXCEPTION 'Registration is blocked during maintenance'
      USING ERRCODE = 'P0001';
  END IF;

  -- Normal profile creation with error handling
  BEGIN
    INSERT INTO public.profiles (user_id, username, balance)
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
      100
    )
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user profile creation failed for %: %', NEW.id, SQLERRM;
  END;

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
-- Name: increment_promotion_click(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_promotion_click(p_promotion_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.track_promotions
  SET clicks_count = clicks_count + 1
  WHERE id = p_promotion_id AND is_active = true AND expires_at > now();
END;
$$;


--
-- Name: increment_promotion_impression(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_promotion_impression(p_promotion_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.track_promotions
  SET impressions_count = impressions_count + 1
  WHERE id = p_promotion_id AND is_active = true AND expires_at > now();
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
-- Name: is_maintenance_active(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_maintenance_active() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT lower(value) = 'true' FROM public.settings WHERE key = 'maintenance_mode'),
    false
  )
$$;


--
-- Name: FUNCTION is_maintenance_active(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_maintenance_active() IS 'Returns true when maintenance mode is enabled';


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
-- Name: process_payment_completion(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_payment_completion(p_payment_id uuid, p_expected_amount integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_payment RECORD;
  v_new_balance INTEGER;
BEGIN
  -- Атомарно захватываем платёж с блокировкой строки
  SELECT * INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_found');
  END IF;

  -- Idempotency: если уже обработан — возвращаем OK без повторного зачисления
  IF v_payment.status = 'completed' THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END IF;

  -- Защита: платёж должен быть в статусе pending
  IF v_payment.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_status', 'current_status', v_payment.status);
  END IF;

  -- Кросс-валидация суммы (если передана от платёжной системы)
  IF p_expected_amount IS NOT NULL AND p_expected_amount != v_payment.amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'amount_mismatch',
      'expected', p_expected_amount, 'actual', v_payment.amount);
  END IF;

  -- Обновляем статус платежа
  UPDATE public.payments
  SET status = 'completed', updated_at = now()
  WHERE id = p_payment_id;

  -- Атомарно зачисляем баланс
  UPDATE public.profiles
  SET balance = balance + v_payment.amount
  WHERE user_id = v_payment.user_id
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'profile_not_found');
  END IF;

  -- Логируем транзакцию
  INSERT INTO public.balance_transactions (
    user_id, amount, balance_after, type, description, reference_id, reference_type
  ) VALUES (
    v_payment.user_id,
    v_payment.amount,
    v_new_balance,
    'topup',
    v_payment.description,
    v_payment.id,
    'payment'
  );

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_payment.user_id,
    'amount', v_payment.amount,
    'new_balance', v_new_balance
  );
END;
$$;


--
-- Name: process_payment_refund(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_payment_refund(p_payment_id uuid, p_refund_amount integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_payment RECORD;
  v_refund_amount INTEGER;
  v_new_balance INTEGER;
BEGIN
  SELECT * INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_found');
  END IF;

  IF v_payment.status = 'refunded' THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END IF;

  IF v_payment.status != 'completed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_completed');
  END IF;

  v_refund_amount := COALESCE(p_refund_amount, v_payment.amount);

  UPDATE public.payments
  SET status = 'refunded', updated_at = now()
  WHERE id = p_payment_id;

  -- Атомарно списываем баланс (не ниже нуля)
  UPDATE public.profiles
  SET balance = GREATEST(0, balance - v_refund_amount)
  WHERE user_id = v_payment.user_id
  RETURNING balance INTO v_new_balance;

  IF FOUND THEN
    INSERT INTO public.balance_transactions (
      user_id, amount, balance_after, type, description, reference_id, reference_type
    ) VALUES (
      v_payment.user_id,
      -v_refund_amount,
      v_new_balance,
      'refund',
      COALESCE('Возврат средств: ' || v_payment.description, 'Возврат средств: платёж #' || p_payment_id::text),
      v_payment.id,
      'payment'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_payment.user_id,
    'refund_amount', v_refund_amount,
    'new_balance', v_new_balance
  );
END;
$$;


--
-- Name: process_store_item_purchase(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_store_item_purchase(p_buyer_id uuid, p_store_item_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_item RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
  v_buyer_balance_before INTEGER;
  v_buyer_balance INTEGER;
  v_seller_balance_before INTEGER;
  v_seller_balance INTEGER;
  v_admin_id UUID;
  v_is_escrow BOOLEAN;
BEGIN
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_item FROM public.store_items
  WHERE id = p_store_item_id AND is_active = true;

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Item not found or not available';
  END IF;

  IF v_item.seller_id = p_buyer_id THEN
    RAISE EXCEPTION 'Cannot purchase your own item';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.item_purchases
    WHERE store_item_id = p_store_item_id AND buyer_id = p_buyer_id
  ) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;

  v_platform_fee := ROUND(v_item.price * 0.1);
  v_net_amount := v_item.price - v_platform_fee;

  -- Escrow only for lyrics
  v_is_escrow := (v_item.item_type = 'lyrics');

  -- Deduct buyer balance
  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = p_buyer_id FOR UPDATE;
  IF v_buyer_balance_before < v_item.price THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  UPDATE public.profiles SET balance = balance - v_item.price
  WHERE user_id = p_buyer_id
  RETURNING balance INTO v_buyer_balance;

  -- Create purchase record
  INSERT INTO public.item_purchases (
    buyer_id, seller_id, store_item_id, item_type, source_id,
    price, license_type, platform_fee, net_amount, admin_status
  )
  VALUES (
    p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type,
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending_review' ELSE 'approved' END
  )
  RETURNING id INTO v_purchase_id;

  -- Create seller earning
  INSERT INTO public.seller_earnings (user_id, amount, source_type, source_id, platform_fee, net_amount, status)
  VALUES (
    v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id, v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending' ELSE 'available' END
  );

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;

  -- Buyer balance transaction (always)
  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase',
    'Покупка: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

  IF v_is_escrow THEN
    -- LYRICS: no seller balance update yet; notify admins
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_item.seller_id,
      'item_sold',
      'Продажа: ' || v_item.title,
      'Ваш текст куплен за ' || v_item.price || ' ₽. Ожидает подтверждения администрации.',
      p_buyer_id,
      'item_purchase',
      v_purchase_id
    );

    FOR v_admin_id IN SELECT user_id FROM public.user_roles WHERE role IN ('admin', 'super_admin')
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (
        v_admin_id,
        'deal_pending_review',
        'Новая сделка на рассмотрении',
        v_item.title || ' — ' || v_item.price || ' ₽ (текст)',
        p_buyer_id,
        'item_purchase',
        v_purchase_id
      );
    END LOOP;
  ELSE
    -- PROMPT/BEAT: instant sale — credit seller immediately
    SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_item.seller_id FOR UPDATE;

    UPDATE public.profiles SET balance = balance + v_net_amount
    WHERE user_id = v_item.seller_id
    RETURNING balance INTO v_seller_balance;

    INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
    VALUES (
      v_item.seller_id, v_net_amount, v_seller_balance_before, v_seller_balance,
      'sale_income',
      'Продажа: ' || v_item.title,
      p_store_item_id, 'store_item'
    );

    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_item.seller_id,
      'item_sold',
      'Продажа: ' || v_item.title,
      'Ваш промпт куплен за ' || v_item.price || ' ₽. Средства зачислены.',
      p_buyer_id,
      'item_purchase',
      v_purchase_id
    );
  END IF;

  -- Handle exclusive items
  IF v_item.is_exclusive THEN
    UPDATE public.store_items SET is_active = false WHERE id = p_store_item_id;

    IF v_item.item_type = 'prompt' THEN
      UPDATE public.user_prompts SET is_public = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'lyrics' THEN
      UPDATE public.lyrics_items SET is_active = false, is_for_sale = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'beat' THEN
      UPDATE public.store_beats SET is_active = false WHERE id = v_item.source_id;
    END IF;
  END IF;

  RETURN v_purchase_id;
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
-- Name: protect_track_critical_fields(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_track_critical_fields() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
  v_bypass text;
BEGIN
  -- Allow updates from trusted RPC (record_track_like_update, record_track_play)
  v_bypass := current_setting('app.bypass_track_protection', true);
  IF v_bypass = 'true' THEN
    RETURN NEW;
  END IF;

  -- Use auth.uid() - more reliable than request.jwt.claim.sub in triggers
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Allow admins AND moderators with moderation permission to update moderation fields
  IF public.is_admin(v_user_id) OR public.has_permission(v_user_id, 'moderation') THEN
    RETURN NEW;
  END IF;

  NEW.likes_count := OLD.likes_count;
  NEW.plays_count := OLD.plays_count;
  NEW.moderation_status := OLD.moderation_status;
  NEW.moderation_reviewed_by := OLD.moderation_reviewed_by;
  NEW.moderation_reviewed_at := OLD.moderation_reviewed_at;
  NEW.voting_result := OLD.voting_result;
  NEW.voting_likes_count := OLD.voting_likes_count;
  NEW.voting_dislikes_count := OLD.voting_dislikes_count;
  NEW.weighted_likes_sum := OLD.weighted_likes_sum;
  NEW.weighted_dislikes_sum := OLD.weighted_dislikes_sum;
  NEW.chart_position := OLD.chart_position;
  NEW.chart_score := OLD.chart_score;
  NEW.downloads_count := OLD.downloads_count;
  NEW.shares_count := OLD.shares_count;

  RETURN NEW;
END;
$$;


--
-- Name: protect_voting_category(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_voting_category() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_protected_id UUID;
BEGIN
  SELECT value::uuid INTO v_protected_id FROM settings WHERE key = 'forum_voting_category_id';
  IF v_protected_id IS NOT NULL AND OLD.id = v_protected_id THEN
    RAISE EXCEPTION 'Cannot delete the voting category. It is a system category.';
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
-- Name: purchase_track_boost(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purchase_track_boost(p_track_id uuid, p_boost_duration_hours integer DEFAULT 1) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_user_balance NUMERIC;
  v_new_balance NUMERIC;
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMP WITH TIME ZONE;
  v_boost_type TEXT;
  v_track_title TEXT;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u043e\u0431\u0445\u043e\u0434\u0438\u043c\u0430 \u0430\u0432\u0442\u043e\u0440\u0438\u0437\u0430\u0446\u0438\u044f');
  END IF;

  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id;

  IF v_track_title IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u0422\u0440\u0435\u043a \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d \u0438\u043b\u0438 \u043d\u0435 \u043f\u0440\u0438\u043d\u0430\u0434\u043b\u0435\u0436\u0438\u0442 \u0432\u0430\u043c');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.track_promotions
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', E'\u0422\u0440\u0435\u043a \u0443\u0436\u0435 \u043f\u0440\u043e\u0434\u0432\u0438\u0433\u0430\u0435\u0442\u0441\u044f');
  END IF;

  CASE p_boost_duration_hours
    WHEN 1 THEN
      v_service_name := 'boost_track_1h';
      v_boost_type := 'standard';
    WHEN 6 THEN
      v_service_name := 'boost_track_6h';
      v_boost_type := 'premium';
    WHEN 24 THEN
      v_service_name := 'boost_track_24h';
      v_boost_type := 'top';
    ELSE RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u0432\u0435\u0440\u043d\u0430\u044f \u0434\u043b\u0438\u0442\u0435\u043b\u044c\u043d\u043e\u0441\u0442\u044c');
  END CASE;

  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;

  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u0423\u0441\u043b\u0443\u0433\u0430 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u0430');
  END IF;

  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id FOR UPDATE;

  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u0434\u043e\u0441\u0442\u0430\u0442\u043e\u0447\u043d\u043e \u0441\u0440\u0435\u0434\u0441\u0442\u0432', 'required', v_price, 'balance', v_user_balance);
  END IF;

  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id
    RETURNING balance INTO v_new_balance;

  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;

  UPDATE public.track_promotions
  SET is_active = false
  WHERE track_id = p_track_id;

  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;

  -- Описание: "Буст трека «Title» на X ч. (Type)"
  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after, metadata
  ) VALUES (
    v_user_id,
    -v_price,
    'purchase',
    E'\u0411\u0443\u0441\u0442 \u0442\u0440\u0435\u043a\u0430 \u00ab' || COALESCE(v_track_title, E'\u2014') || E'\u00bb \u043d\u0430 ' || p_boost_duration_hours || E' \u0447. (' || v_boost_type || ')',
    v_promotion_id,
    'promotion',
    v_user_balance,
    v_new_balance,
    jsonb_build_object('track_id', p_track_id, 'track_title', v_track_title, 'duration_hours', p_boost_duration_hours, 'boost_type', v_boost_type, 'expires_at', v_expires_at)
  );

  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', v_price
  );
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
-- Name: radio_award_listen_xp(uuid, uuid, integer, integer, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text DEFAULT NULL::text, p_session_id text DEFAULT NULL::text, p_ip_hash text DEFAULT NULL::text, p_is_afk_verified boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_listen_percent NUMERIC;
  v_xp_earned INTEGER := 0;
  v_xp_today INTEGER;
  v_daily_cap INTEGER := 50;
  v_min_percent NUMERIC := 60;
  v_xp_per_listen NUMERIC := 2;
  v_result JSONB;
  v_arena_vote_cast BOOLEAN := FALSE;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_track_duration_sec <= 0 THEN
    p_track_duration_sec := 1;
  END IF;

  v_listen_percent := (p_listen_duration_sec::NUMERIC / p_track_duration_sec) * 100;

  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  IF v_listen_percent >= v_min_percent THEN
    v_xp_earned := LEAST(
      GREATEST(1, (v_xp_per_listen * (v_listen_percent / 100))::INTEGER),
      v_daily_cap - v_xp_today
    );
    IF v_xp_earned < 1 THEN v_xp_earned := 0; END IF;
  END IF;

  INSERT INTO public.radio_listens (
    user_id, track_id, session_id, listen_duration_sec, track_duration_sec,
    listen_percent, xp_earned, reaction, ip_hash, is_afk_verified
  ) VALUES (
    p_user_id, p_track_id, p_session_id, p_listen_duration_sec, p_track_duration_sec,
    v_listen_percent, v_xp_earned, p_reaction, p_ip_hash, p_is_afk_verified
  );

  IF p_reaction IN ('like', 'love') AND v_listen_percent >= 50 AND p_is_afk_verified = TRUE THEN
    v_arena_vote_cast := cast_radio_vote_for_arena(p_user_id, p_track_id, p_listen_duration_sec);
  END IF;

  IF v_xp_earned > 0 THEN
    PERFORM public.fn_add_xp(p_user_id, v_xp_earned, 'music', false);
  END IF;

  v_xp_today := v_xp_today + v_xp_earned;

  v_result := jsonb_build_object(
    'ok', true, 'xp_earned', v_xp_earned, 'listen_percent', v_listen_percent,
    'xp_today', v_xp_today, 'daily_cap', v_daily_cap,
    'listens_today', (SELECT COUNT(*) FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap,
    'arena_vote_cast', v_arena_vote_cast
  );

  RETURN v_result;
END;
$$;


--
-- Name: radio_create_next_slot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_create_next_slot() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_max_slot INTEGER;
  v_open_count INTEGER;
  v_new_id UUID;
BEGIN
  SELECT COUNT(*) INTO v_open_count FROM public.radio_slots WHERE status IN ('open', 'bidding');
  IF v_open_count >= 2 THEN RETURN NULL; END IF;

  SELECT COALESCE(MAX(slot_number), 0) INTO v_max_slot FROM public.radio_slots;

  INSERT INTO public.radio_slots (slot_number, starts_at, ends_at, status)
  VALUES (v_max_slot + 1, NOW(), NOW() + INTERVAL '1 hour', 'open')
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;


--
-- Name: radio_heartbeat(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_heartbeat(p_user_id uuid, p_session_id text, p_genre_filter uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO public.radio_listeners (user_id, session_id, genre_filter, last_heartbeat)
  VALUES (p_user_id, p_session_id, p_genre_filter, NOW())
  ON CONFLICT ON CONSTRAINT unique_radio_listener
  DO UPDATE SET
    last_heartbeat = NOW(),
    genre_filter = COALESCE(EXCLUDED.genre_filter, radio_listeners.genre_filter);

  DELETE FROM public.radio_listeners
  WHERE last_heartbeat < NOW() - INTERVAL '3 minutes';

  SELECT COUNT(*) INTO v_count
  FROM public.radio_listeners
  WHERE last_heartbeat > NOW() - INTERVAL '2 minutes';

  RETURN jsonb_build_object(
    'ok', true,
    'listeners_count', v_count
  );
END;
$$;


--
-- Name: radio_place_bid(uuid, uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_slot RECORD;
  v_config JSONB;
  v_min_bid INTEGER;
  v_bid_step INTEGER;
  v_highest INTEGER;
  v_balance INTEGER;
  v_old_bid RECORD;
  v_new_bid_id UUID;
  v_track_title TEXT;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_found');
  END IF;
  IF v_slot.status NOT IN ('open', 'bidding') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  SELECT value INTO v_config FROM public.radio_config WHERE key = 'auction';
  v_min_bid  := COALESCE((v_config ->> 'min_bid_rub')::int,  10);
  v_bid_step := COALESCE((v_config ->> 'bid_step_rub')::int, 5);

  IF COALESCE((v_config ->> 'enabled')::boolean, true) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', 'auction_disabled');
  END IF;

  SELECT COALESCE(MAX(amount), 0) INTO v_highest
    FROM public.radio_bids WHERE slot_id = p_slot_id AND status = 'active';

  IF p_amount < v_min_bid OR (v_highest > 0 AND p_amount < v_highest + v_bid_step) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low',
      'min_required', GREATEST(v_min_bid, v_highest + v_bid_step));
  END IF;

  SELECT id, amount INTO v_old_bid
    FROM public.radio_bids
    WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active'
    ORDER BY amount DESC LIMIT 1;

  IF v_old_bid.id IS NOT NULL THEN
    UPDATE public.profiles SET balance = balance + v_old_bid.amount WHERE user_id = p_user_id;
    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT p_user_id, v_old_bid.amount, 'refund',
           E'\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u043f\u0440\u0435\u0434\u044b\u0434\u0443\u0449\u0435\u0439 \u0441\u0442\u0430\u0432\u043a\u0438 \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number,
           'radio_bid', v_old_bid.id,
           balance - v_old_bid.amount, balance
    FROM public.profiles WHERE user_id = p_user_id;
    UPDATE public.radio_bids SET status = 'outbid' WHERE id = v_old_bid.id;
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;
  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  SELECT p_user_id, -p_amount, 'debit',
         E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || p_amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number,
         'radio_slot', p_slot_id,
         balance + p_amount, balance
  FROM public.profiles WHERE user_id = p_user_id;

  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount)
  VALUES (p_slot_id, p_user_id, p_track_id, p_amount)
  RETURNING id INTO v_new_bid_id;

  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1 WHERE id = p_slot_id;
  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id;

  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  VALUES (
    p_user_id, 'radio_bid_placed',
    E'\u0421\u0442\u0430\u0432\u043a\u0430 \u043f\u0440\u0438\u043d\u044f\u0442\u0430',
    E'\u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || p_amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number
      || E' (\u0442\u0440\u0435\u043a: ' || COALESCE(v_track_title, E'\u2014') || ')',
    jsonb_build_object('slot_id', p_slot_id, 'bid_id', v_new_bid_id, 'amount', p_amount, 'track_id', p_track_id),
    '/radio'
  );

  INSERT INTO public.notifications (user_id, type, title, message, data, link)
  SELECT
    rb.user_id, 'radio_bid_outbid',
    E'\u0412\u0430\u0448\u0443 \u0441\u0442\u0430\u0432\u043a\u0443 \u043f\u0435\u0440\u0435\u0431\u0438\u043b\u0438!',
    E'\u0421\u0442\u0430\u0432\u043a\u0430 ' || rb.amount || E'\u20bd \u043d\u0430 \u0441\u043b\u043e\u0442 #' || v_slot.slot_number
      || E' \u043f\u0435\u0440\u0435\u0431\u0438\u0442\u0430 (' || p_amount || E'\u20bd). \u041f\u043e\u0434\u043d\u0438\u043c\u0438\u0442\u0435 \u0441\u0442\u0430\u0432\u043a\u0443!',
    jsonb_build_object('slot_id', p_slot_id, 'your_amount', rb.amount, 'new_highest', p_amount),
    '/radio'
  FROM public.radio_bids rb
  WHERE rb.slot_id = p_slot_id AND rb.status = 'active'
    AND rb.user_id != p_user_id AND rb.amount < p_amount;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$$;


--
-- Name: radio_place_prediction(uuid, uuid, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_place_prediction(p_user_id uuid, p_track_id uuid, p_bet_amount integer, p_predicted_hit boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_min INTEGER := 5;
  v_max INTEGER := 100;
  v_balance INTEGER;
  v_expires_hours INTEGER := 24;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_bet_amount < v_min OR p_bet_amount > v_max THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bet_amount', 'min', v_min, 'max', v_max);
  END IF;

  IF EXISTS (SELECT 1 FROM public.radio_predictions WHERE user_id = p_user_id AND track_id = p_track_id AND status = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_predicted');
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_bet_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  INSERT INTO public.radio_predictions (user_id, track_id, bet_amount, predicted_hit, expires_at)
  VALUES (p_user_id, p_track_id, p_bet_amount, p_predicted_hit, now() + (v_expires_hours || ' hours')::interval);

  UPDATE public.profiles SET balance = balance - p_bet_amount WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'bet_amount', p_bet_amount, 'predicted_hit', p_predicted_hit, 'expires_in_hours', v_expires_hours);
END;
$$;


--
-- Name: radio_refund_losers(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_refund_losers(p_slot_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_slot RECORD;
  v_bid RECORD;
  v_refund_count INTEGER := 0;
BEGIN
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN RETURN 0; END IF;

  FOR v_bid IN
    SELECT rb.id, rb.user_id, rb.amount, rb.track_id
    FROM public.radio_bids rb
    WHERE rb.slot_id = p_slot_id
      AND rb.status = 'active'
      AND rb.user_id != COALESCE(v_slot.winner_user_id, '00000000-0000-0000-0000-000000000000'::uuid)
  LOOP
    UPDATE public.profiles SET balance = balance + v_bid.amount WHERE user_id = v_bid.user_id;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
    SELECT v_bid.user_id, v_bid.amount, 'refund',
           E'\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u0441\u0442\u0430\u0432\u043a\u0438: \u0441\u043b\u043e\u0442 #' || v_slot.slot_number || E' \u0437\u0430\u0432\u0435\u0440\u0448\u0451\u043d',
           'radio_bid', v_bid.id,
           balance - v_bid.amount, balance
    FROM public.profiles WHERE user_id = v_bid.user_id;

    UPDATE public.radio_bids SET status = 'refunded' WHERE id = v_bid.id;

    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_bid.user_id,
      'radio_bid_refunded',
      E'\u0421\u0442\u0430\u0432\u043a\u0430 \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430',
      E'\u0421\u043b\u043e\u0442 #' || v_slot.slot_number || E' \u0437\u0430\u0432\u0435\u0440\u0448\u0451\u043d. \u0412\u0430\u0448\u0430 \u0441\u0442\u0430\u0432\u043a\u0430 ' || v_bid.amount || E'\u20bd \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0430 \u043d\u0430 \u0431\u0430\u043b\u0430\u043d\u0441.',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_bid.amount, 'refund', true),
      '/radio'
    );

    v_refund_count := v_refund_count + 1;
  END LOOP;

  IF v_slot.winner_user_id IS NOT NULL THEN
    UPDATE public.radio_bids SET status = 'won'
    WHERE slot_id = p_slot_id AND user_id = v_slot.winner_user_id AND status = 'active';

    INSERT INTO public.notifications (user_id, type, title, message, data, link)
    VALUES (
      v_slot.winner_user_id,
      'radio_bid_won',
      E'\u0412\u044b \u0432\u044b\u0438\u0433\u0440\u0430\u043b\u0438 \u0430\u0443\u043a\u0446\u0438\u043e\u043d!',
      E'\u0412\u0430\u0448 \u0442\u0440\u0435\u043a \u043f\u043e\u043f\u0430\u0434\u0451\u0442 \u0432 \u044d\u0444\u0438\u0440 \u0440\u0430\u0434\u0438\u043e (\u0441\u043b\u043e\u0442 #' || v_slot.slot_number || E', \u0441\u0442\u0430\u0432\u043a\u0430 ' || v_slot.winning_bid || E'\u20bd)!',
      jsonb_build_object('slot_id', p_slot_id, 'amount', v_slot.winning_bid, 'track_id', v_slot.winner_track_id),
      '/radio'
    );
  END IF;

  RETURN v_refund_count;
END;
$$;


--
-- Name: radio_resolve_predictions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_resolve_predictions() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_count INTEGER := 0;
  v_rec RECORD;
  v_hit_threshold INTEGER := 5;
  v_actual_hit BOOLEAN;
BEGIN
  FOR v_rec IN
    SELECT rp.id, rp.track_id, rp.predicted_hit, rp.bet_amount, rp.user_id
    FROM public.radio_predictions rp
    WHERE rp.status = 'pending' AND rp.expires_at < now()
  LOOP
    SELECT (COALESCE(t.likes_count, 0) >= v_hit_threshold) INTO v_actual_hit
    FROM public.tracks t WHERE t.id = v_rec.track_id;

    UPDATE public.radio_predictions SET
      actual_result = v_actual_hit,
      status = CASE WHEN v_actual_hit = v_rec.predicted_hit THEN 'won' ELSE 'lost' END,
      payout = CASE WHEN v_actual_hit = v_rec.predicted_hit THEN (v_rec.bet_amount * 1.8)::INTEGER ELSE 0 END
    WHERE id = v_rec.id;

    IF v_actual_hit = v_rec.predicted_hit THEN
      UPDATE public.profiles SET balance = balance + (v_rec.bet_amount * 1.8)::INTEGER WHERE user_id = v_rec.user_id;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


--
-- Name: radio_skip_ad(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.radio_skip_ad(p_user_id uuid, p_ad_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_skip_price INTEGER := 5;
  v_balance INTEGER;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR v_caller != p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_skip_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - v_skip_price WHERE user_id = p_user_id;
  UPDATE public.radio_ad_placements SET clicks = clicks + 1 WHERE id = p_ad_id;

  RETURN jsonb_build_object('ok', true, 'charged', v_skip_price);
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
-- Name: record_track_like_update(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_track_like_update(p_track_id uuid, p_delta integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF p_delta = 0 THEN
    RETURN;
  END IF;

  -- Bypass protect_track_critical_fields for this transaction
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  -- Update tracks.likes_count
  UPDATE public.tracks
  SET likes_count = GREATEST(0, COALESCE(likes_count, 0) + p_delta)
  WHERE id = p_track_id;

  -- Update track_daily_stats.likes_count for today
  IF p_delta > 0 THEN
    INSERT INTO public.track_daily_stats (track_id, date, likes_count)
    VALUES (p_track_id, CURRENT_DATE, p_delta)
    ON CONFLICT (track_id, date)
    DO UPDATE SET likes_count = track_daily_stats.likes_count + p_delta;
  ELSE
    -- On unlike, decrement today's likes_count (don't go below 0)
    UPDATE public.track_daily_stats
    SET likes_count = GREATEST(0, COALESCE(likes_count, 0) + p_delta)
    WHERE track_id = p_track_id AND date = CURRENT_DATE;
  END IF;
END;
$$;


--
-- Name: record_track_play(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_track_play(p_track_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  UPDATE public.tracks
  SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id;

  INSERT INTO public.track_daily_stats (track_id, date, plays_count)
  VALUES (p_track_id, CURRENT_DATE, 1)
  ON CONFLICT (track_id, date)
  DO UPDATE SET plays_count = track_daily_stats.plays_count + 1;
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
         xp_social = COALESCE(forum_user_stats.xp_social, 0) + v_final_xp,
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
      VALUES (v_reporter_id, 'qa_report_resolved', v_final_xp, v_rep, 'social', 'qa_ticket', p_ticket_id,
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

CREATE FUNCTION public.resolve_track_voting(p_track_id uuid, p_manual_result text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_total_weight NUMERIC;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_like_ratio NUMERIC;
  v_result TEXT;
  v_new_status TEXT;
  v_new_distribution_status TEXT;
  v_is_distribution_voting BOOLEAN;
  v_closure_msg TEXT;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF NOT public.is_admin(COALESCE(v_caller, '00000000-0000-0000-0000-000000000000'::uuid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Admin required');
  END IF;

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;

  v_is_distribution_voting := (v_track.distribution_status = 'voting');

  IF p_manual_result IS NOT NULL THEN
    v_result := p_manual_result;
    v_new_status := CASE WHEN p_manual_result = 'approved' THEN 'pending' ELSE 'rejected' END;
    v_new_distribution_status := CASE
      WHEN v_is_distribution_voting AND p_manual_result = 'approved' THEN 'pending_master'
      WHEN v_is_distribution_voting AND p_manual_result = 'rejected' THEN 'rejected'
      ELSE v_track.distribution_status
    END;

    UPDATE public.tracks SET
      moderation_status = v_new_status,
      distribution_status = v_new_distribution_status,
      voting_result = 'manual_override_' || p_manual_result,
      is_public = false
    WHERE id = p_track_id;

    IF v_track.forum_topic_id IS NOT NULL THEN
      v_closure_msg := E'\u2705 **\u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u043e. \u0420\u0435\u0448\u0435\u043d\u0438\u0435 \u043f\u0440\u0438\u043d\u044f\u0442\u043e.**' || E'\n\n' ||
        CASE WHEN p_manual_result = 'approved'
          THEN E'\u0422\u0440\u0435\u043a \u043e\u0434\u043e\u0431\u0440\u0435\u043d \u0434\u043b\u044f \u0434\u0438\u0441\u0442\u0440\u0438\u0431\u0443\u0446\u0438\u0438.'
          ELSE E'\u0422\u0440\u0435\u043a \u043d\u0435 \u043f\u0440\u043e\u0448\u0451\u043b \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435.'
        END;
      INSERT INTO public.forum_posts (topic_id, user_id, content)
      VALUES (v_track.forum_topic_id, '00000000-0000-0000-0000-000000000000', v_closure_msg);
      UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
    END IF;

    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track.user_id, 'voting_result',
      CASE WHEN p_manual_result = 'approved'
        THEN E'\U0001f389 \u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u043f\u0440\u043e\u0439\u0434\u0435\u043d\u043e!'
        ELSE E'\u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u043e'
      END,
      CASE WHEN p_manual_result = 'approved'
        THEN E'\u0422\u0440\u0435\u043a "' || v_track.title || E'" \u0443\u0441\u043f\u0435\u0448\u043d\u043e \u043f\u0440\u043e\u0448\u0451\u043b \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435.'
        ELSE E'\u041a \u0441\u043e\u0436\u0430\u043b\u0435\u043d\u0438\u044e, \u0442\u0440\u0435\u043a "' || v_track.title || E'" \u043d\u0435 \u043d\u0430\u0431\u0440\u0430\u043b \u0434\u043e\u0441\u0442\u0430\u0442\u043e\u0447\u043d\u043e \u0433\u043e\u043b\u043e\u0441\u043e\u0432.'
      END,
      'track', p_track_id
    );

    RETURN jsonb_build_object(
      'success', true, 'result', p_manual_result, 'method', 'manual_override',
      'new_moderation_status', v_new_status, 'new_distribution_status', v_new_distribution_status
    );
  END IF;

  v_total_weight := COALESCE(v_track.weighted_likes_sum, 0) + COALESCE(v_track.weighted_dislikes_sum, 0);
  v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);

  SELECT COALESCE(value::integer, 10) INTO v_min_votes
  FROM public.settings WHERE key = 'voting_min_votes';
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio
  FROM public.settings WHERE key = 'voting_approval_ratio';

  IF v_total_weight > 0 THEN
    v_like_ratio := COALESCE(v_track.weighted_likes_sum, 0) / v_total_weight;
  ELSIF v_total_votes > 0 THEN
    v_like_ratio := COALESCE(v_track.voting_likes_count, 0)::numeric / v_total_votes;
  ELSE
    v_like_ratio := 0;
  END IF;

  IF v_total_votes < v_min_votes AND v_total_weight < v_min_votes THEN
    v_result := 'rejected'; v_new_status := 'rejected';
  ELSIF v_total_weight > 0 AND v_total_weight >= v_min_votes THEN
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved'; v_new_status := 'pending';
    ELSE
      v_result := 'rejected'; v_new_status := 'rejected';
    END IF;
  ELSIF v_total_votes >= v_min_votes THEN
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved'; v_new_status := 'pending';
    ELSE
      v_result := 'rejected'; v_new_status := 'rejected';
    END IF;
  ELSE
    v_result := 'rejected'; v_new_status := 'rejected';
  END IF;

  v_new_distribution_status := CASE
    WHEN v_is_distribution_voting AND v_result = 'voting_approved' THEN 'pending_master'
    WHEN v_is_distribution_voting AND v_result = 'rejected' THEN 'rejected'
    ELSE v_track.distribution_status
  END;

  UPDATE public.tracks SET
    moderation_status = v_new_status,
    distribution_status = v_new_distribution_status,
    voting_result = v_result,
    is_public = false
  WHERE id = p_track_id;

  IF v_track.forum_topic_id IS NOT NULL THEN
    v_closure_msg := E'\u2705 **\u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u043e.**' || E'\n\n' ||
      CASE WHEN v_result = 'voting_approved'
        THEN E'\u0422\u0440\u0435\u043a \u043e\u0434\u043e\u0431\u0440\u0435\u043d (' || ROUND(v_like_ratio * 100) || E'% \u043f\u043e\u043b\u043e\u0436\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0445).'
        ELSE E'\u0422\u0440\u0435\u043a \u043d\u0435 \u043f\u0440\u043e\u0448\u0451\u043b (' || ROUND(v_like_ratio * 100) || E'% \u043f\u043e\u043b\u043e\u0436\u0438\u0442., \u0442\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044f ' || ROUND(v_approval_ratio * 100) || '%).'
      END;
    INSERT INTO public.forum_posts (topic_id, user_id, content)
    VALUES (v_track.forum_topic_id, '00000000-0000-0000-0000-000000000000', v_closure_msg);
    UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_track.user_id, 'voting_result',
    CASE WHEN v_result = 'voting_approved'
      THEN E'\U0001f389 \u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u043f\u0440\u043e\u0439\u0434\u0435\u043d\u043e!'
      ELSE E'\u0413\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u043e'
    END,
    CASE WHEN v_result = 'voting_approved'
      THEN E'\u0422\u0440\u0435\u043a "' || v_track.title || E'" \u0443\u0441\u043f\u0435\u0448\u043d\u043e \u043f\u0440\u043e\u0448\u0451\u043b \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435.'
      ELSE E'\u041a \u0441\u043e\u0436\u0430\u043b\u0435\u043d\u0438\u044e, \u0442\u0440\u0435\u043a "' || v_track.title || E'" \u043d\u0435 \u043d\u0430\u0431\u0440\u0430\u043b \u0434\u043e\u0441\u0442\u0430\u0442\u043e\u0447\u043d\u043e \u0433\u043e\u043b\u043e\u0441\u043e\u0432.'
    END,
    'track', p_track_id
  );

  RETURN jsonb_build_object(
    'success', true, 'result', v_result,
    'total_votes', v_total_votes, 'like_ratio', v_like_ratio,
    'min_votes_required', v_min_votes, 'approval_ratio_required', v_approval_ratio,
    'new_moderation_status', v_new_status, 'new_distribution_status', v_new_distribution_status
  );
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
-- Name: revoke_vote(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_vote(p_track_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_vote_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT id INTO v_vote_id FROM weighted_votes WHERE track_id = p_track_id AND user_id = v_user_id;
  IF v_vote_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO vote_audit_log (vote_id, action, details)
  VALUES (v_vote_id, 'revoke', jsonb_build_object('revoked_by', v_user_id));

  DELETE FROM weighted_votes WHERE id = v_vote_id;
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

CREATE FUNCTION public.send_track_to_voting(p_track_id uuid, p_duration_days integer DEFAULT NULL::integer, p_voting_type text DEFAULT 'public'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_duration INTEGER;
  v_ends_at TIMESTAMP WITH TIME ZONE;
  v_track_owner UUID;
  v_current_status TEXT;
  v_current_ends_at TIMESTAMP WITH TIME ZONE;
  v_caller UUID;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;

  SELECT moderation_status, voting_ends_at, user_id
    INTO v_current_status, v_current_ends_at, v_track_owner
  FROM public.tracks WHERE id = p_track_id;

  IF v_track_owner IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;

  IF v_caller IS NOT NULL AND v_caller != v_track_owner AND NOT public.is_admin(v_caller) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only track owner or admin can send to voting');
  END IF;

  IF v_current_status = 'voting' AND v_current_ends_at IS NOT NULL AND v_current_ends_at > now() THEN
    RAISE EXCEPTION 'Трек уже находится в активном голосовании. Дождитесь завершения или завершите его досрочно.';
  END IF;

  IF p_duration_days IS NULL THEN
    SELECT COALESCE(value::integer, 7) INTO v_duration
    FROM public.settings WHERE key = 'voting_duration_days';
  ELSE
    v_duration := p_duration_days;
  END IF;

  IF p_voting_type = 'internal' AND p_duration_days IS NULL THEN
    v_duration := 1;
  END IF;

  v_ends_at := now() + (v_duration || ' days')::interval;

  UPDATE public.tracks SET
    moderation_status = 'voting',
    distribution_status = CASE WHEN distribution_status = 'pending_moderation' THEN 'voting' ELSE distribution_status END,
    voting_type = p_voting_type,
    voting_started_at = now(),
    voting_ends_at = v_ends_at,
    voting_result = 'pending',
    voting_likes_count = 0,
    voting_dislikes_count = 0,
    is_public = CASE WHEN p_voting_type = 'public' THEN true ELSE false END
  WHERE id = p_track_id;

  IF v_track_owner IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track_owner, 'voting_started',
      CASE WHEN p_voting_type = 'public'
        THEN E'\U0001f5f3\ufe0f \u0422\u0440\u0435\u043a \u043d\u0430 \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0438 \u0441\u043e\u043e\u0431\u0449\u0435\u0441\u0442\u0432\u0430'
        ELSE E'\U0001f5f3\ufe0f \u0422\u0440\u0435\u043a \u043d\u0430 \u0432\u043d\u0443\u0442\u0440\u0435\u043d\u043d\u0435\u043c \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0438'
      END,
      E'\u0412\u0430\u0448 \u0442\u0440\u0435\u043a \u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d \u043d\u0430 \u0433\u043e\u043b\u043e\u0441\u043e\u0432\u0430\u043d\u0438\u0435. \u0420\u0435\u0437\u0443\u043b\u044c\u0442\u0430\u0442\u044b \u0431\u0443\u0434\u0443\u0442 \u0438\u0437\u0432\u0435\u0441\u0442\u043d\u044b \u0447\u0435\u0440\u0435\u0437 ' || v_duration || E' \u0434\u043d\u0435\u0439.',
      'track', p_track_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'voting_type', p_voting_type,
    'voting_ends_at', v_ends_at, 'duration_days', v_duration
  );
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
-- Name: sync_lyrics_to_store_items(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_lyrics_to_store_items() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM store_items
    WHERE source_id = OLD.id AND item_type = 'lyrics' AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  IF NEW.is_for_sale = true AND COALESCE(NEW.price, 0) > 0 THEN
    INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, created_at, updated_at)
    VALUES (
      NEW.user_id,
      'lyrics',
      NEW.id,
      COALESCE(NULLIF(TRIM(NEW.title), ''), 'Без названия'),
      NEW.description,
      NEW.price,
      COALESCE(NEW.license_type, 'standard'),
      COALESCE(NEW.is_exclusive, false),
      true,
      NEW.created_at,
      now()
    )
    ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
      title = EXCLUDED.title,
      description = EXCLUDED.description,
      price = EXCLUDED.price,
      license_type = EXCLUDED.license_type,
      is_exclusive = EXCLUDED.is_exclusive,
      is_active = true,
      updated_at = now();
  ELSE
    UPDATE store_items SET is_active = false, updated_at = now()
    WHERE source_id = NEW.id AND item_type = 'lyrics' AND seller_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: sync_prompt_to_store_items(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_prompt_to_store_items() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM store_items
    WHERE source_id = OLD.id AND item_type = 'prompt' AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  IF NEW.is_public = true THEN
    INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, created_at, updated_at)
    VALUES (
      NEW.user_id,
      'prompt',
      NEW.id,
      COALESCE(NULLIF(TRIM(NEW.title), ''), 'Без названия'),
      NEW.description,
      COALESCE(NEW.price, 0),
      COALESCE(NEW.license_type, 'standard'),
      COALESCE(NEW.is_exclusive, false),
      true,
      NEW.created_at,
      now()
    )
    ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
      title = EXCLUDED.title,
      description = EXCLUDED.description,
      price = EXCLUDED.price,
      license_type = EXCLUDED.license_type,
      is_exclusive = EXCLUDED.is_exclusive,
      is_active = true,
      updated_at = now();
  ELSE
    UPDATE store_items SET is_active = false, updated_at = now()
    WHERE source_id = NEW.id AND item_type = 'prompt' AND seller_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: take_voting_snapshot(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.take_voting_snapshot(p_track_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_snapshot_id UUID;
  v_likes NUMERIC;
  v_dislikes NUMERIC;
  v_total INTEGER;
  v_rate NUMERIC;
BEGIN
  SELECT
    COALESCE(SUM(CASE WHEN vote_type IN ('like', 'superlike') THEN final_weight ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN vote_type = 'dislike' THEN final_weight ELSE 0 END), 0),
    COUNT(*)
  INTO v_likes, v_dislikes, v_total
  FROM weighted_votes WHERE track_id = p_track_id;

  v_rate := CASE WHEN (v_likes + v_dislikes) > 0 THEN v_likes / (v_likes + v_dislikes) ELSE 0 END;

  INSERT INTO voting_snapshots (track_id, weighted_likes, weighted_dislikes, total_voters, approval_rate)
  VALUES (p_track_id, v_likes, v_dislikes, v_total, v_rate)
  RETURNING id INTO v_snapshot_id;

  RETURN v_snapshot_id;
END;
$$;


--
-- Name: transliterate_ru(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transliterate_ru(input text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT translate(lower(coalesce(input, '')),
    'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
    'abvgdeejziiklmnoprstufhcchshshyeyuya'
  );
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
-- Name: update_voter_ranks(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_voter_ranks() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE voter_profiles SET
    voter_rank = CASE
      WHEN votes_cast_total >= 50 AND COALESCE(accuracy_rate, 0) >= 0.7 THEN 'oracle'
      WHEN COALESCE(accuracy_rate, 0) >= 0.5 THEN 'tastemaker'
      WHEN COALESCE(accuracy_rate, 0) >= 0.3 THEN 'curator'
      ELSE 'scout'
    END,
    updated_at = now();
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
    created_at timestamp with time zone DEFAULT now(),
    metadata jsonb
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
-- Name: chart_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chart_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    "position" integer NOT NULL,
    previous_position integer,
    chart_score numeric DEFAULT 0 NOT NULL,
    chart_type text NOT NULL,
    chart_date date NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chart_entries_chart_type_check CHECK ((chart_type = ANY (ARRAY['daily'::text, 'weekly'::text, 'alltime'::text])))
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
    updated_at timestamp with time zone DEFAULT now(),
    description_ru text,
    parent_id uuid
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
    has_poll boolean DEFAULT false,
    slug text NOT NULL
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
    buyer_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    price integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'completed'::text,
    created_at timestamp with time zone DEFAULT now(),
    license_type text DEFAULT 'standard'::text NOT NULL,
    platform_fee integer DEFAULT 0,
    net_amount integer DEFAULT 0,
    download_url text,
    store_item_id uuid NOT NULL,
    item_type text DEFAULT 'lyrics'::text NOT NULL,
    source_id uuid NOT NULL,
    admin_status text DEFAULT 'pending_review'::text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    admin_notes text,
    blockchain_tx_id text,
    copyright_status text DEFAULT 'none'::text
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
    lyrics_id uuid NOT NULL,
    user_id uuid NOT NULL,
    method text DEFAULT 'blockchain'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    content_hash text,
    timestamp_hash text,
    certificate_url text,
    external_id text,
    author_name text,
    deposited_at timestamp with time zone,
    error_message text,
    price_rub integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: weighted_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weighted_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    user_id uuid NOT NULL,
    vote_type text NOT NULL,
    raw_weight numeric DEFAULT 1.0 NOT NULL,
    fraud_multiplier numeric DEFAULT 1.0 NOT NULL,
    combo_bonus numeric DEFAULT 0.0 NOT NULL,
    final_weight numeric DEFAULT 1.0 NOT NULL,
    fingerprint_hash text,
    ip_address inet,
    context jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT weighted_votes_combo_bonus_check CHECK (((combo_bonus >= (0)::numeric) AND (combo_bonus <= 0.5))),
    CONSTRAINT weighted_votes_fraud_multiplier_check CHECK (((fraud_multiplier >= (0)::numeric) AND (fraud_multiplier <= 1.0))),
    CONSTRAINT weighted_votes_raw_weight_check CHECK (((raw_weight >= (0)::numeric) AND (raw_weight <= 5.0))),
    CONSTRAINT weighted_votes_vote_type_check CHECK ((vote_type = ANY (ARRAY['like'::text, 'dislike'::text, 'superlike'::text])))
);


--
-- Name: mv_voting_live; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.mv_voting_live AS
 SELECT wv.track_id,
    sum(
        CASE
            WHEN (wv.vote_type = 'like'::text) THEN wv.final_weight
            ELSE (0)::numeric
        END) AS weighted_likes,
    sum(
        CASE
            WHEN (wv.vote_type = 'dislike'::text) THEN wv.final_weight
            ELSE (0)::numeric
        END) AS weighted_dislikes,
    sum(
        CASE
            WHEN (wv.vote_type = 'superlike'::text) THEN wv.final_weight
            ELSE (0)::numeric
        END) AS weighted_superlikes,
    count(DISTINCT wv.user_id) AS total_voters
   FROM (public.weighted_votes wv
     JOIN public.tracks t ON ((t.id = wv.track_id)))
  WHERE ((t.moderation_status = 'voting'::text) AND (t.voting_ends_at > now()))
  GROUP BY wv.track_id
  WITH NO DATA;


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
-- Name: payment_callbacks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_callbacks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_system text NOT NULL,
    inv_id text NOT NULL,
    out_sum text,
    signature_valid boolean DEFAULT false NOT NULL,
    client_ip text,
    raw_params jsonb,
    result text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
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
    contests_won integer DEFAULT 0 NOT NULL,
    slug text,
    CONSTRAINT profiles_balance_non_negative CHECK ((balance >= 0))
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
-- Name: radio_listeners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_listeners (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    session_id text NOT NULL,
    last_heartbeat timestamp with time zone DEFAULT now() NOT NULL,
    genre_filter uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: radio_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.radio_schedule (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    source text DEFAULT 'algorithm'::text NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    scheduled_at timestamp with time zone,
    played_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: reposts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reposts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: seo_ai_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seo_ai_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    config_key text NOT NULL,
    config_value text NOT NULL,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: seo_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seo_metadata (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    page_key text,
    title text,
    description text,
    keywords text[],
    og_title text,
    og_description text,
    og_image_url text,
    canonical_url text,
    robots_directive text DEFAULT 'index, follow'::text,
    ai_generated boolean DEFAULT false,
    ai_generated_at timestamp with time zone,
    ai_model text,
    yandex_verification text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by uuid,
    CONSTRAINT seo_metadata_entity_type_check CHECK ((entity_type = ANY (ARRAY['track'::text, 'profile'::text, 'forum_topic'::text, 'page'::text, 'contest'::text])))
);


--
-- Name: seo_robots_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seo_robots_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_agent text NOT NULL,
    rule_type text NOT NULL,
    path text NOT NULL,
    crawl_delay integer,
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT seo_robots_rules_rule_type_check CHECK ((rule_type = ANY (ARRAY['allow'::text, 'disallow'::text])))
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
    boost_type text DEFAULT 'standard'::text,
    is_active boolean DEFAULT true,
    impressions_count integer DEFAULT 0,
    clicks_count integer DEFAULT 0,
    price_paid numeric DEFAULT 0
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
-- Name: vote_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vote_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vote_id uuid,
    action text NOT NULL,
    details jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT vote_audit_log_action_check CHECK ((action = ANY (ARRAY['cast'::text, 'change'::text, 'revoke'::text, 'fraud_flag'::text])))
);


--
-- Name: vote_combos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vote_combos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    combo_length integer DEFAULT 0 NOT NULL,
    bonus_earned numeric DEFAULT 0 NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    last_vote_at timestamp with time zone DEFAULT now() NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


--
-- Name: voter_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voter_profiles (
    user_id uuid NOT NULL,
    votes_cast_total integer DEFAULT 0 NOT NULL,
    votes_cast_30d integer DEFAULT 0 NOT NULL,
    correct_predictions integer DEFAULT 0 NOT NULL,
    accuracy_rate numeric DEFAULT 0,
    current_combo integer DEFAULT 0 NOT NULL,
    best_combo integer DEFAULT 0 NOT NULL,
    last_vote_at timestamp with time zone,
    daily_votes_today integer DEFAULT 0 NOT NULL,
    daily_votes_date date,
    voter_rank text DEFAULT 'scout'::text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT voter_profiles_accuracy_rate_check CHECK (((accuracy_rate >= (0)::numeric) AND (accuracy_rate <= (1)::numeric))),
    CONSTRAINT voter_profiles_voter_rank_check CHECK ((voter_rank = ANY (ARRAY['scout'::text, 'curator'::text, 'tastemaker'::text, 'oracle'::text])))
);


--
-- Name: voting_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voting_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    track_id uuid NOT NULL,
    weighted_likes numeric DEFAULT 0 NOT NULL,
    weighted_dislikes numeric DEFAULT 0 NOT NULL,
    total_voters integer DEFAULT 0 NOT NULL,
    approval_rate numeric DEFAULT 0,
    snapshot_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: chart_entries chart_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chart_entries
    ADD CONSTRAINT chart_entries_pkey PRIMARY KEY (id);


--
-- Name: chart_entries chart_entries_track_id_chart_type_chart_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chart_entries
    ADD CONSTRAINT chart_entries_track_id_chart_type_chart_date_key UNIQUE (track_id, chart_type, chart_date);


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
-- Name: forum_topics forum_topics_category_id_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_topics
    ADD CONSTRAINT forum_topics_category_id_slug_key UNIQUE (category_id, slug);


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
-- Name: payment_callbacks payment_callbacks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_callbacks
    ADD CONSTRAINT payment_callbacks_pkey PRIMARY KEY (id);


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
-- Name: radio_listeners radio_listeners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listeners
    ADD CONSTRAINT radio_listeners_pkey PRIMARY KEY (id);


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
-- Name: radio_schedule radio_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_schedule
    ADD CONSTRAINT radio_schedule_pkey PRIMARY KEY (id);


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
-- Name: reposts reposts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reposts
    ADD CONSTRAINT reposts_pkey PRIMARY KEY (id);


--
-- Name: reposts reposts_user_id_track_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reposts
    ADD CONSTRAINT reposts_user_id_track_id_key UNIQUE (user_id, track_id);


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
-- Name: seo_ai_config seo_ai_config_config_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seo_ai_config
    ADD CONSTRAINT seo_ai_config_config_key_key UNIQUE (config_key);


--
-- Name: seo_ai_config seo_ai_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seo_ai_config
    ADD CONSTRAINT seo_ai_config_pkey PRIMARY KEY (id);


--
-- Name: seo_metadata seo_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seo_metadata
    ADD CONSTRAINT seo_metadata_pkey PRIMARY KEY (id);


--
-- Name: seo_robots_rules seo_robots_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seo_robots_rules
    ADD CONSTRAINT seo_robots_rules_pkey PRIMARY KEY (id);


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
-- Name: store_items store_items_seller_type_source_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_items
    ADD CONSTRAINT store_items_seller_type_source_unique UNIQUE (seller_id, item_type, source_id);


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
-- Name: radio_listeners unique_radio_listener; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listeners
    ADD CONSTRAINT unique_radio_listener UNIQUE (user_id, session_id);


--
-- Name: weighted_votes unique_user_track_weighted_vote; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weighted_votes
    ADD CONSTRAINT unique_user_track_weighted_vote UNIQUE (track_id, user_id);


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
-- Name: vote_audit_log vote_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_pkey PRIMARY KEY (id);


--
-- Name: vote_combos vote_combos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vote_combos
    ADD CONSTRAINT vote_combos_pkey PRIMARY KEY (id);


--
-- Name: voter_profiles voter_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voter_profiles
    ADD CONSTRAINT voter_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: voting_snapshots voting_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voting_snapshots
    ADD CONSTRAINT voting_snapshots_pkey PRIMARY KEY (id);


--
-- Name: weighted_votes weighted_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weighted_votes
    ADD CONSTRAINT weighted_votes_pkey PRIMARY KEY (id);


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
-- Name: addon_services_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addon_services_name_key ON public.addon_services USING btree (name);


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
-- Name: idx_chart_entries_type_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chart_entries_type_date ON public.chart_entries USING btree (chart_type, chart_date, "position");


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
-- Name: idx_forum_categories_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_forum_categories_parent_id ON public.forum_categories USING btree (parent_id) WHERE (parent_id IS NOT NULL);


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
-- Name: idx_lyrics_deposits_lyrics_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lyrics_deposits_lyrics_id ON public.lyrics_deposits USING btree (lyrics_id);


--
-- Name: idx_lyrics_deposits_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lyrics_deposits_status ON public.lyrics_deposits USING btree (status);


--
-- Name: idx_lyrics_deposits_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lyrics_deposits_user_id ON public.lyrics_deposits USING btree (user_id);


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
-- Name: idx_mv_voting_live_track; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_mv_voting_live_track ON public.mv_voting_live USING btree (track_id);


--
-- Name: idx_payment_callbacks_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_callbacks_created_at ON public.payment_callbacks USING btree (created_at);


--
-- Name: idx_payment_callbacks_inv_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_callbacks_inv_id ON public.payment_callbacks USING btree (inv_id);


--
-- Name: idx_payments_external_id_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_external_id_lookup ON public.payments USING btree (external_id, payment_system) WHERE (status = 'pending'::text);


--
-- Name: idx_payments_external_id_system_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payments_external_id_system_unique ON public.payments USING btree (external_id, payment_system) WHERE (external_id IS NOT NULL);


--
-- Name: idx_payments_user_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_user_date ON public.payments USING btree (user_id, created_at DESC);


--
-- Name: idx_profiles_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_profiles_slug ON public.profiles USING btree (slug) WHERE (slug IS NOT NULL);


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
-- Name: idx_radio_listeners_heartbeat; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listeners_heartbeat ON public.radio_listeners USING btree (last_heartbeat DESC);


--
-- Name: idx_radio_listens_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listens_track ON public.radio_listens USING btree (track_id, created_at DESC);


--
-- Name: idx_radio_listens_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listens_user ON public.radio_listens USING btree (user_id, created_at DESC);


--
-- Name: idx_radio_listens_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_listens_user_created ON public.radio_listens USING btree (user_id, created_at);


--
-- Name: idx_radio_predictions_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_predictions_track ON public.radio_predictions USING btree (track_id, status);


--
-- Name: idx_radio_predictions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_predictions_user ON public.radio_predictions USING btree (user_id, status);


--
-- Name: idx_radio_predictions_user_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_predictions_user_status ON public.radio_predictions USING btree (user_id, status);


--
-- Name: idx_radio_queue_genre; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_queue_genre ON public.radio_queue USING btree (genre_id) WHERE (NOT is_played);


--
-- Name: idx_radio_queue_is_played; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_queue_is_played ON public.radio_queue USING btree (is_played);


--
-- Name: idx_radio_queue_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_queue_position ON public.radio_queue USING btree ("position") WHERE (NOT is_played);


--
-- Name: idx_radio_schedule_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_schedule_pending ON public.radio_schedule USING btree (priority DESC, scheduled_at) WHERE (played_at IS NULL);


--
-- Name: idx_radio_schedule_played; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_radio_schedule_played ON public.radio_schedule USING btree (played_at DESC) WHERE (played_at IS NOT NULL);


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
-- Name: idx_reposts_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reposts_track ON public.reposts USING btree (track_id);


--
-- Name: idx_reposts_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reposts_user ON public.reposts USING btree (user_id);


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
-- Name: idx_seo_metadata_empty; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_seo_metadata_empty ON public.seo_metadata USING btree (entity_type) WHERE (title IS NULL);


--
-- Name: idx_seo_metadata_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_seo_metadata_entity ON public.seo_metadata USING btree (entity_type, entity_id);


--
-- Name: idx_seo_metadata_entity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_seo_metadata_entity_unique ON public.seo_metadata USING btree (entity_type, entity_id) WHERE (entity_id IS NOT NULL);


--
-- Name: idx_seo_metadata_page; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_seo_metadata_page ON public.seo_metadata USING btree (entity_type, page_key);


--
-- Name: idx_seo_metadata_page_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_seo_metadata_page_unique ON public.seo_metadata USING btree (entity_type, page_key) WHERE (page_key IS NOT NULL);


--
-- Name: idx_store_items_seller_type_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_store_items_seller_type_source ON public.store_items USING btree (seller_id, item_type, source_id);


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
-- Name: idx_tracks_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tracks_slug ON public.tracks USING btree (slug) WHERE (slug IS NOT NULL);


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
-- Name: idx_vote_audit_log_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vote_audit_log_created ON public.vote_audit_log USING btree (created_at DESC);


--
-- Name: idx_vote_audit_log_vote_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vote_audit_log_vote_id ON public.vote_audit_log USING btree (vote_id);


--
-- Name: idx_vote_combos_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vote_combos_user_active ON public.vote_combos USING btree (user_id, is_active) WHERE (is_active = true);


--
-- Name: idx_voting_snapshots_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voting_snapshots_track ON public.voting_snapshots USING btree (track_id, snapshot_at DESC);


--
-- Name: idx_weighted_votes_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weighted_votes_created ON public.weighted_votes USING btree (created_at);


--
-- Name: idx_weighted_votes_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weighted_votes_fingerprint ON public.weighted_votes USING btree (fingerprint_hash, track_id) WHERE (fingerprint_hash IS NOT NULL);


--
-- Name: idx_weighted_votes_track_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weighted_votes_track_type ON public.weighted_votes USING btree (track_id, vote_type);


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
-- Name: lyrics_items trg_delete_store_items_on_lyrics_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_delete_store_items_on_lyrics_delete AFTER DELETE ON public.lyrics_items FOR EACH ROW EXECUTE FUNCTION public.fn_delete_store_items_on_source_delete();


--
-- Name: user_prompts trg_delete_store_items_on_prompt_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_delete_store_items_on_prompt_delete AFTER DELETE ON public.user_prompts FOR EACH ROW EXECUTE FUNCTION public.fn_delete_store_items_on_source_delete();


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
-- Name: profiles trg_profile_slug; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_profile_slug BEFORE INSERT OR UPDATE OF username ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.generate_profile_slug();


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
-- Name: tracks trg_protect_track_critical_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_track_critical_fields BEFORE UPDATE ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.protect_track_critical_fields();


--
-- Name: forum_categories trg_protect_voting_category; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_voting_category BEFORE DELETE ON public.forum_categories FOR EACH ROW EXECUTE FUNCTION public.protect_voting_category();


--
-- Name: qa_tickets trg_qa_ticket_number; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_qa_ticket_number BEFORE INSERT ON public.qa_tickets FOR EACH ROW WHEN ((new.ticket_number IS NULL)) EXECUTE FUNCTION public.qa_generate_ticket_number();


--
-- Name: qa_tickets trg_qa_tickets_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_qa_tickets_updated BEFORE UPDATE ON public.qa_tickets FOR EACH ROW EXECUTE FUNCTION public.qa_update_timestamp();


--
-- Name: lyrics_items trg_sync_lyrics_to_store; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_lyrics_to_store AFTER INSERT OR DELETE OR UPDATE ON public.lyrics_items FOR EACH ROW EXECUTE FUNCTION public.sync_lyrics_to_store_items();


--
-- Name: user_prompts trg_sync_prompt_to_store; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_prompt_to_store AFTER INSERT OR DELETE OR UPDATE ON public.user_prompts FOR EACH ROW EXECUTE FUNCTION public.sync_prompt_to_store_items();


--
-- Name: tracks trg_track_slug; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_track_slug BEFORE INSERT OR UPDATE OF title ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.generate_track_slug();


--
-- Name: contest_votes trg_update_total_votes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_total_votes AFTER INSERT OR DELETE ON public.contest_votes FOR EACH ROW EXECUTE FUNCTION public.update_total_votes_received();


--
-- Name: track_votes trigger_check_voting_eligibility; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_check_voting_eligibility BEFORE INSERT ON public.track_votes FOR EACH ROW EXECUTE FUNCTION public.check_voting_eligibility();


--
-- Name: lyrics_deposits update_lyrics_deposits_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lyrics_deposits_updated_at BEFORE UPDATE ON public.lyrics_deposits FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


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
-- Name: chart_entries chart_entries_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chart_entries
    ADD CONSTRAINT chart_entries_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


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
-- Name: forum_categories forum_categories_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forum_categories
    ADD CONSTRAINT forum_categories_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.forum_categories(id) ON DELETE SET NULL;


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
-- Name: item_purchases item_purchases_store_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_purchases
    ADD CONSTRAINT item_purchases_store_item_id_fkey FOREIGN KEY (store_item_id) REFERENCES public.store_items(id) ON DELETE CASCADE;


--
-- Name: lyrics_deposits lyrics_deposits_lyrics_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lyrics_deposits
    ADD CONSTRAINT lyrics_deposits_lyrics_id_fkey FOREIGN KEY (lyrics_id) REFERENCES public.lyrics_items(id) ON DELETE CASCADE;


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
-- Name: radio_listeners radio_listeners_genre_filter_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listeners
    ADD CONSTRAINT radio_listeners_genre_filter_fkey FOREIGN KEY (genre_filter) REFERENCES public.genres(id);


--
-- Name: radio_listeners radio_listeners_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_listeners
    ADD CONSTRAINT radio_listeners_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


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
-- Name: radio_schedule radio_schedule_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.radio_schedule
    ADD CONSTRAINT radio_schedule_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


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
-- Name: reposts reposts_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reposts
    ADD CONSTRAINT reposts_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: reposts reposts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reposts
    ADD CONSTRAINT reposts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


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
-- Name: seo_metadata seo_metadata_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seo_metadata
    ADD CONSTRAINT seo_metadata_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


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
-- Name: vote_audit_log vote_audit_log_vote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_vote_id_fkey FOREIGN KEY (vote_id) REFERENCES public.weighted_votes(id) ON DELETE SET NULL;


--
-- Name: vote_combos vote_combos_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vote_combos
    ADD CONSTRAINT vote_combos_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: voter_profiles voter_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voter_profiles
    ADD CONSTRAINT voter_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: voting_snapshots voting_snapshots_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voting_snapshots
    ADD CONSTRAINT voting_snapshots_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


--
-- Name: weighted_votes weighted_votes_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weighted_votes
    ADD CONSTRAINT weighted_votes_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE CASCADE;


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
-- Name: radio_ad_placements Admins can delete radio_ad_placements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete radio_ad_placements" ON public.radio_ad_placements FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role]))))));


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
-- Name: radio_ad_placements Admins can insert radio_ad_placements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert radio_ad_placements" ON public.radio_ad_placements FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role]))))));


--
-- Name: seller_earnings Admins can manage all earnings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage all earnings" ON public.seller_earnings TO authenticated USING (public.is_admin(auth.uid()));


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
-- Name: radio_ad_placements Admins can select all radio_ad_placements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can select all radio_ad_placements" ON public.radio_ad_placements FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role]))))));


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
-- Name: moderator_permissions Admins can update permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update permissions" ON public.moderator_permissions FOR UPDATE USING (public.is_admin(auth.uid()));


--
-- Name: moderator_presets Admins can update presets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update presets" ON public.moderator_presets FOR UPDATE USING (public.is_admin(auth.uid()));


--
-- Name: radio_ad_placements Admins can update radio_ad_placements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update radio_ad_placements" ON public.radio_ad_placements FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role]))))));


--
-- Name: track_promotions Admins can view all promotions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all promotions" ON public.track_promotions FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: tracks Admins can view all tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all tracks" ON public.tracks FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.user_roles
  WHERE ((user_roles.user_id = auth.uid()) AND (user_roles.role = ANY (ARRAY['admin'::public.app_role, 'super_admin'::public.app_role, 'moderator'::public.app_role]))))));


--
-- Name: vote_audit_log Admins can view vote audit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view vote audit" ON public.vote_audit_log FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: forum_posts Admins delete posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete posts" ON public.forum_posts FOR DELETE USING (true);


--
-- Name: forum_topics Admins view all topics; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins view all topics" ON public.forum_topics FOR SELECT USING ((public.has_role(auth.uid(), 'admin'::public.app_role) OR public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'moderator'::public.app_role)));


--
-- Name: radio_ad_placements Anyone can read radio_ad_placements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can read radio_ad_placements" ON public.radio_ad_placements FOR SELECT USING (((is_active = true) AND ((ends_at IS NULL) OR (ends_at > now()))));


--
-- Name: radio_bids Anyone can read radio_bids; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can read radio_bids" ON public.radio_bids FOR SELECT USING (true);


--
-- Name: radio_config Anyone can read radio_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can read radio_config" ON public.radio_config FOR SELECT USING (true);


--
-- Name: radio_queue Anyone can read radio_queue; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can read radio_queue" ON public.radio_queue FOR SELECT USING (true);


--
-- Name: radio_slots Anyone can read radio_slots; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can read radio_slots" ON public.radio_slots FOR SELECT USING (true);


--
-- Name: radio_listeners Anyone can see radio listeners; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can see radio listeners" ON public.radio_listeners FOR SELECT USING (true);


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
-- Name: chart_entries Anyone can view chart entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view chart entries" ON public.chart_entries FOR SELECT USING (true);


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
-- Name: radio_schedule Anyone can view radio schedule; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view radio schedule" ON public.radio_schedule FOR SELECT USING (true);


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
-- Name: voting_snapshots Anyone can view voting snapshots; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view voting snapshots" ON public.voting_snapshots FOR SELECT USING (true);


--
-- Name: weighted_votes Anyone can view weighted votes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view weighted votes" ON public.weighted_votes FOR SELECT USING (true);


--
-- Name: weighted_votes Authenticated users can vote; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can vote" ON public.weighted_votes FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: forum_posts Authenticated users create posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users create posts" ON public.forum_posts FOR INSERT WITH CHECK (true);


--
-- Name: role_change_logs Only admins can view logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can view logs" ON public.role_change_logs FOR SELECT USING (public.is_admin(auth.uid()));


--
-- Name: messages Prevent messages in closed conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Prevent messages in closed conversations" ON public.messages AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK ((NOT (EXISTS ( SELECT 1
   FROM public.conversations
  WHERE ((conversations.id = messages.conversation_id) AND (conversations.type = 'admin_support'::text) AND (conversations.status = 'closed'::text))))));


--
-- Name: seller_earnings Sellers can view own earnings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Sellers can view own earnings" ON public.seller_earnings FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: seller_earnings Service can insert earnings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service can insert earnings" ON public.seller_earnings FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: radio_queue Service can manage radio_queue; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service can manage radio_queue" ON public.radio_queue TO service_role USING (true) WITH CHECK (true);


--
-- Name: balance_transactions Service role can insert transactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can insert transactions" ON public.balance_transactions FOR INSERT TO service_role WITH CHECK (true);


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
-- Name: reposts Users can delete own reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own reposts" ON public.reposts FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: tracks Users can delete own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own tracks" ON public.tracks FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: weighted_votes Users can delete own vote; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete own vote" ON public.weighted_votes FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: track_likes Users can insert own likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own likes" ON public.track_likes FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: profiles Users can insert own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: reposts Users can insert own reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own reposts" ON public.reposts FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: tracks Users can insert own tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own tracks" ON public.tracks FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: radio_listens Users can insert radio_listens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert radio_listens" ON public.radio_listens FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: radio_listeners Users can manage own listener entry; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own listener entry" ON public.radio_listeners USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: radio_listens Users can read own radio_listens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read own radio_listens" ON public.radio_listens FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: radio_predictions Users can read own radio_predictions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read own radio_predictions" ON public.radio_predictions FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: role_invitations Users can respond to own invitations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can respond to own invitations" ON public.role_invitations FOR UPDATE USING (((user_id = auth.uid()) OR public.is_admin(auth.uid())));


--
-- Name: track_bookmarks Users can unbookmark tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can unbookmark tracks" ON public.track_bookmarks FOR DELETE USING (((auth.uid() = user_id) OR public.is_admin(auth.uid())));


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
-- Name: weighted_votes Users can update own vote; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own vote" ON public.weighted_votes FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: track_likes Users can view all likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all likes" ON public.track_likes FOR SELECT USING (true);


--
-- Name: profiles Users can view all profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all profiles" ON public.profiles FOR SELECT USING (true);


--
-- Name: reposts Users can view all reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all reposts" ON public.reposts FOR SELECT USING (true);


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
-- Name: vote_combos Users can view own vote combos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own vote combos" ON public.vote_combos FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: voter_profiles Users can view own voter profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own voter profile" ON public.voter_profiles FOR SELECT USING ((auth.uid() = user_id));


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
-- Name: seo_ai_config admins_manage_seo_ai_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_manage_seo_ai_config ON public.seo_ai_config TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: seo_metadata admins_manage_seo_metadata; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_manage_seo_metadata ON public.seo_metadata TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));


--
-- Name: seo_robots_rules admins_manage_seo_robots; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_manage_seo_robots ON public.seo_robots_rules TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));


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
-- Name: chart_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chart_entries ENABLE ROW LEVEL SECURITY;

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
-- Name: lyrics_deposits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lyrics_deposits ENABLE ROW LEVEL SECURITY;

--
-- Name: lyrics_deposits lyrics_deposits_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_deposits_admin ON public.lyrics_deposits USING (public.is_admin(auth.uid()));


--
-- Name: lyrics_deposits lyrics_deposits_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_deposits_insert ON public.lyrics_deposits FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: lyrics_deposits lyrics_deposits_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_deposits_select_own ON public.lyrics_deposits FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: lyrics_deposits lyrics_deposits_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_deposits_update ON public.lyrics_deposits FOR UPDATE USING (((auth.uid() = user_id) OR public.is_admin(auth.uid())));


--
-- Name: lyrics_items lyrics_items_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_admin ON public.lyrics_items USING (public.is_admin(auth.uid()));


--
-- Name: lyrics_items lyrics_items_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_delete ON public.lyrics_items FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: lyrics_items lyrics_items_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_insert ON public.lyrics_items FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: lyrics_items lyrics_items_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_select_own ON public.lyrics_items FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: lyrics_items lyrics_items_select_public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_select_public ON public.lyrics_items FOR SELECT USING (((is_public = true) AND (is_for_sale = true) AND (is_active = true)));


--
-- Name: lyrics_items lyrics_items_select_purchased; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_select_purchased ON public.lyrics_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public.item_purchases ip
     JOIN public.store_items si ON ((si.id = ip.store_item_id)))
  WHERE ((ip.buyer_id = auth.uid()) AND (si.item_type = 'lyrics'::text) AND (si.source_id = lyrics_items.id)))));


--
-- Name: lyrics_items lyrics_items_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lyrics_items_update ON public.lyrics_items FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: comment_likes maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.comment_likes AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: gallery_items maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.gallery_items AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: generated_lyrics maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.generated_lyrics AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: playlist_tracks maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.playlist_tracks AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: playlists maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.playlists AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: reposts maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.reposts AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_comments maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.track_comments AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_likes maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.track_likes AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_reactions maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.track_reactions AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: tracks maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.tracks AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: user_blocks maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.user_blocks AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: user_follows maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.user_follows AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: user_prompts maintenance_block_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_delete ON public.user_prompts AS RESTRICTIVE FOR DELETE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: audio_separations maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.audio_separations AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: bug_reports maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.bug_reports AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: comment_likes maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.comment_likes AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: contest_entries maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.contest_entries AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: contest_votes maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.contest_votes AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: gallery_items maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.gallery_items AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: generated_lyrics maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.generated_lyrics AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: messages maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.messages AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: notifications maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.notifications AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: playlist_tracks maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.playlist_tracks AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: playlists maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.playlists AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: promo_videos maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.promo_videos AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: reposts maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.reposts AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: support_tickets maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.support_tickets AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_addons maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_addons AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_comments maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_comments AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_deposits maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_deposits AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_likes maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_likes AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_promotions maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_promotions AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: track_reactions maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.track_reactions AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: tracks maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.tracks AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: user_blocks maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.user_blocks AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: user_follows maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.user_follows AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: user_prompts maintenance_block_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_insert ON public.user_prompts AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());


--
-- Name: audio_separations maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.audio_separations AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: gallery_items maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.gallery_items AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: messages maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.messages AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: playlist_tracks maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.playlist_tracks AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: playlists maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.playlists AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: profiles maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.profiles AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: promo_videos maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.promo_videos AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_addons maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.track_addons AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_comments maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.track_comments AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: track_deposits maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.track_deposits AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: tracks maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.tracks AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


--
-- Name: user_prompts maintenance_block_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY maintenance_block_update ON public.user_prompts AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.can_write_during_maintenance());


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
-- Name: payment_callbacks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment_callbacks ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: seo_ai_config public_read_seo_ai_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY public_read_seo_ai_config ON public.seo_ai_config FOR SELECT TO authenticated USING (true);


--
-- Name: seo_metadata public_read_seo_metadata; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY public_read_seo_metadata ON public.seo_metadata FOR SELECT TO anon, authenticated USING ((is_active = true));


--
-- Name: seo_robots_rules public_read_seo_robots; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY public_read_seo_robots ON public.seo_robots_rules FOR SELECT TO anon, authenticated USING ((is_active = true));


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
-- Name: radio_listeners; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_listeners ENABLE ROW LEVEL SECURITY;

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
-- Name: radio_schedule; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_schedule ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_slots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.radio_slots ENABLE ROW LEVEL SECURITY;

--
-- Name: radio_slots radio_slots_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY radio_slots_read ON public.radio_slots FOR SELECT USING (true);


--
-- Name: reposts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reposts ENABLE ROW LEVEL SECURITY;

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
-- Name: seo_ai_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seo_ai_config ENABLE ROW LEVEL SECURITY;

--
-- Name: seo_metadata; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seo_metadata ENABLE ROW LEVEL SECURITY;

--
-- Name: seo_robots_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seo_robots_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_callbacks service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_only ON public.payment_callbacks USING ((auth.role() = 'service_role'::text)) WITH CHECK ((auth.role() = 'service_role'::text));


--
-- Name: seo_ai_config service_role_seo_ai_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_seo_ai_config ON public.seo_ai_config TO service_role USING (true) WITH CHECK (true);


--
-- Name: seo_metadata service_role_seo_metadata; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_seo_metadata ON public.seo_metadata TO service_role USING (true) WITH CHECK (true);


--
-- Name: seo_robots_rules service_role_seo_robots; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_seo_robots ON public.seo_robots_rules TO service_role USING (true) WITH CHECK (true);


--
-- Name: store_items store_items_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_admin ON public.store_items USING (public.is_admin(auth.uid()));


--
-- Name: store_items store_items_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_delete ON public.store_items FOR DELETE USING ((auth.uid() = seller_id));


--
-- Name: store_items store_items_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_insert ON public.store_items FOR INSERT WITH CHECK ((auth.uid() = seller_id));


--
-- Name: store_items store_items_select_active; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_select_active ON public.store_items FOR SELECT USING ((is_active = true));


--
-- Name: store_items store_items_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_select_own ON public.store_items FOR SELECT USING ((auth.uid() = seller_id));


--
-- Name: store_items store_items_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_items_update ON public.store_items FOR UPDATE USING ((auth.uid() = seller_id));


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
-- Name: vote_audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vote_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: vote_combos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vote_combos ENABLE ROW LEVEL SECURITY;

--
-- Name: voter_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.voter_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: voting_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.voting_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: weighted_votes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.weighted_votes ENABLE ROW LEVEL SECURITY;

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

GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION admin_annul_vote(p_vote_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_annul_vote(p_vote_id uuid, p_reason text) TO authenticated;


--
-- Name: FUNCTION admin_approve_purchase(p_purchase_id uuid, p_admin_notes text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_approve_purchase(p_purchase_id uuid, p_admin_notes text) TO authenticated;


--
-- Name: FUNCTION admin_end_voting_early(p_track_id uuid, p_result text, p_reason text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_end_voting_early(p_track_id uuid, p_result text, p_reason text) TO authenticated;


--
-- Name: FUNCTION admin_extend_promotion(p_promotion_id uuid, p_hours integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_extend_promotion(p_promotion_id uuid, p_hours integer) TO authenticated;


--
-- Name: FUNCTION admin_get_active_votings(p_filter text, p_sort text, p_page integer, p_per_page integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_active_votings(p_filter text, p_sort text, p_page integer, p_per_page integer) TO authenticated;


--
-- Name: FUNCTION admin_get_all_promotions(p_active_only boolean, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_all_promotions(p_active_only boolean, p_limit integer, p_offset integer) TO authenticated;


--
-- Name: FUNCTION admin_get_deal_blockchain_info(p_purchase_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_deal_blockchain_info(p_purchase_id uuid) TO authenticated;


--
-- Name: FUNCTION admin_get_deal_content(p_source_id uuid, p_item_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_deal_content(p_source_id uuid, p_item_type text) TO authenticated;


--
-- Name: FUNCTION admin_get_flagged_votes(p_page integer, p_per_page integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_flagged_votes(p_page integer, p_per_page integer) TO authenticated;


--
-- Name: FUNCTION admin_get_voting_dashboard(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_get_voting_dashboard() TO authenticated;


--
-- Name: FUNCTION admin_reject_purchase(p_purchase_id uuid, p_admin_notes text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_reject_purchase(p_purchase_id uuid, p_admin_notes text) TO authenticated;


--
-- Name: FUNCTION admin_stop_promotion(p_promotion_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_stop_promotion(p_promotion_id uuid) TO authenticated;


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
-- Name: FUNCTION can_write_during_maintenance(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_write_during_maintenance() TO authenticated;
GRANT ALL ON FUNCTION public.can_write_during_maintenance() TO service_role;


--
-- Name: FUNCTION check_maintenance_access(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_maintenance_access() TO authenticated;
GRANT ALL ON FUNCTION public.check_maintenance_access() TO service_role;


--
-- Name: FUNCTION check_user_achievements(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_user_achievements(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION close_admin_conversation(p_conversation_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.close_admin_conversation(p_conversation_id uuid) TO authenticated;


--
-- Name: FUNCTION create_admin_conversation(p_target_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_admin_conversation(p_target_user_id uuid) TO authenticated;


--
-- Name: FUNCTION create_conversation_with_user(p_other_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_conversation_with_user(p_other_user_id uuid) TO authenticated;


--
-- Name: FUNCTION create_voting_forum_topic(p_track_id uuid, p_moderator_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_voting_forum_topic(p_track_id uuid, p_moderator_id uuid) TO authenticated;


--
-- Name: FUNCTION deactivate_expired_promotions(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.deactivate_expired_promotions() TO authenticated;


--
-- Name: FUNCTION debit_balance(p_user_id uuid, p_amount integer, p_description text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.debit_balance(p_user_id uuid, p_amount integer, p_description text) TO authenticated;


--
-- Name: FUNCTION find_user_by_short_id(short_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.find_user_by_short_id(short_id text) TO authenticated;
GRANT ALL ON FUNCTION public.find_user_by_short_id(short_id text) TO anon;


--
-- Name: FUNCTION fn_add_xp(p_user_id uuid, p_amount numeric, p_category text, p_admin_override boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_add_xp(p_user_id uuid, p_amount numeric, p_category text, p_admin_override boolean) TO authenticated;


--
-- Name: FUNCTION get_boosted_tracks(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_boosted_tracks(p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_boosted_tracks(p_limit integer) TO anon;


--
-- Name: FUNCTION get_creator_earnings_profile(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_creator_earnings_profile(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_economy_health(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_economy_health() TO authenticated;


--
-- Name: FUNCTION get_hero_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_hero_stats() TO anon;
GRANT ALL ON FUNCTION public.get_hero_stats() TO authenticated;


--
-- Name: FUNCTION get_l2e_admin_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_l2e_admin_stats() TO authenticated;
GRANT ALL ON FUNCTION public.get_l2e_admin_stats() TO anon;


--
-- Name: FUNCTION get_marketplace_items(p_item_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_marketplace_items(p_item_type text) TO authenticated;
GRANT ALL ON FUNCTION public.get_marketplace_items(p_item_type text) TO anon;


--
-- Name: FUNCTION get_or_create_referral_code(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_or_create_referral_code(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_prediction_votes(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_prediction_votes(p_track_id uuid) TO authenticated;


--
-- Name: FUNCTION get_radio_listeners(p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_listeners(p_limit integer) TO anon;
GRANT ALL ON FUNCTION public.get_radio_listeners(p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_radio_smart_queue(p_user_id uuid, p_genre_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_smart_queue(p_user_id uuid, p_genre_id uuid, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_radio_smart_queue(p_user_id uuid, p_genre_id uuid, p_limit integer) TO anon;


--
-- Name: FUNCTION get_radio_stats(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_stats() TO authenticated;
GRANT ALL ON FUNCTION public.get_radio_stats() TO anon;


--
-- Name: FUNCTION get_radio_xp_today(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_radio_xp_today(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_reputation_leaderboard(p_type text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_reputation_leaderboard(p_type text, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_reputation_leaderboard(p_type text, p_limit integer) TO anon;


--
-- Name: FUNCTION get_reputation_profile(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_reputation_profile(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_smart_feed(p_user_id uuid, p_stream text, p_genre_id uuid, p_offset integer, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_smart_feed(p_user_id uuid, p_stream text, p_genre_id uuid, p_offset integer, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_smart_feed(p_user_id uuid, p_stream text, p_genre_id uuid, p_offset integer, p_limit integer) TO anon;


--
-- Name: TABLE tracks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tracks TO service_role;


--
-- Name: FUNCTION get_track_by_share_token(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_by_share_token(p_token text) TO anon;
GRANT ALL ON FUNCTION public.get_track_by_share_token(p_token text) TO authenticated;


--
-- Name: FUNCTION get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION get_track_prompt_info(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_track_prompt_info(p_track_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_track_prompt_info(p_track_id uuid) TO anon;


--
-- Name: FUNCTION get_user_stats(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_stats(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION has_purchased_item(p_item_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_purchased_item(p_item_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION has_purchased_prompt(p_prompt_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_purchased_prompt(p_prompt_id uuid, p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION increment_promotion_click(p_promotion_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.increment_promotion_click(p_promotion_id uuid) TO anon;
GRANT ALL ON FUNCTION public.increment_promotion_click(p_promotion_id uuid) TO authenticated;


--
-- Name: FUNCTION increment_promotion_impression(p_promotion_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.increment_promotion_impression(p_promotion_id uuid) TO anon;
GRANT ALL ON FUNCTION public.increment_promotion_impression(p_promotion_id uuid) TO authenticated;


--
-- Name: FUNCTION increment_prompt_downloads(p_prompt_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.increment_prompt_downloads(p_prompt_id uuid) TO authenticated;


--
-- Name: FUNCTION is_admin(_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin(_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_admin(_user_id uuid) TO anon;


--
-- Name: FUNCTION is_maintenance_active(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_maintenance_active() TO authenticated;
GRANT ALL ON FUNCTION public.is_maintenance_active() TO service_role;


--
-- Name: FUNCTION process_payment_refund(p_payment_id uuid, p_refund_amount integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_payment_refund(p_payment_id uuid, p_refund_amount integer) TO authenticated;


--
-- Name: FUNCTION process_store_item_purchase(p_buyer_id uuid, p_store_item_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_store_item_purchase(p_buyer_id uuid, p_store_item_id uuid) TO authenticated;


--
-- Name: FUNCTION purchase_ad_free(p_user_id uuid, p_days integer, p_cost integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.purchase_ad_free(p_user_id uuid, p_days integer, p_cost integer) TO authenticated;


--
-- Name: FUNCTION purchase_track_boost(p_track_id uuid, p_boost_duration_hours integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.purchase_track_boost(p_track_id uuid, p_boost_duration_hours integer) TO authenticated;


--
-- Name: FUNCTION radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text, p_is_afk_verified boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_award_listen_xp(p_user_id uuid, p_track_id uuid, p_listen_duration_sec integer, p_track_duration_sec integer, p_reaction text, p_session_id text, p_ip_hash text, p_is_afk_verified boolean) TO authenticated;


--
-- Name: FUNCTION radio_create_next_slot(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_create_next_slot() TO service_role;


--
-- Name: FUNCTION radio_heartbeat(p_user_id uuid, p_session_id text, p_genre_filter uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_heartbeat(p_user_id uuid, p_session_id text, p_genre_filter uuid) TO authenticated;


--
-- Name: FUNCTION radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount integer) TO authenticated;
GRANT ALL ON FUNCTION public.radio_place_bid(p_user_id uuid, p_slot_id uuid, p_track_id uuid, p_amount integer) TO service_role;


--
-- Name: FUNCTION radio_refund_losers(p_slot_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_refund_losers(p_slot_id uuid) TO service_role;


--
-- Name: FUNCTION radio_resolve_predictions(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_resolve_predictions() TO authenticated;


--
-- Name: FUNCTION radio_skip_ad(p_user_id uuid, p_ad_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.radio_skip_ad(p_user_id uuid, p_ad_id uuid) TO authenticated;


--
-- Name: FUNCTION record_track_like_update(p_track_id uuid, p_delta integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_track_like_update(p_track_id uuid, p_delta integer) TO authenticated;


--
-- Name: FUNCTION record_track_play(p_track_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_track_play(p_track_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.record_track_play(p_track_id uuid) TO anon;


--
-- Name: FUNCTION resolve_track_voting(p_track_id uuid, p_manual_result text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.resolve_track_voting(p_track_id uuid, p_manual_result text) TO authenticated;


--
-- Name: FUNCTION send_track_to_voting(p_track_id uuid, p_duration_days integer, p_voting_type text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.send_track_to_voting(p_track_id uuid, p_duration_days integer, p_voting_type text) TO authenticated;


--
-- Name: FUNCTION unblock_user(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.unblock_user(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION unhide_contest_comment(p_comment_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.unhide_contest_comment(p_comment_id uuid) TO authenticated;


--
-- Name: TABLE achievements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.achievements TO service_role;


--
-- Name: TABLE ad_campaign_slots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_campaign_slots TO service_role;


--
-- Name: TABLE ad_campaigns; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_campaigns TO service_role;


--
-- Name: TABLE ad_creatives; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_creatives TO service_role;


--
-- Name: TABLE ad_impressions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_impressions TO service_role;


--
-- Name: TABLE ad_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_settings TO service_role;


--
-- Name: TABLE ad_slots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_slots TO service_role;


--
-- Name: TABLE ad_targeting; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_targeting TO service_role;


--
-- Name: TABLE addon_services; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.addon_services TO service_role;


--
-- Name: TABLE admin_announcements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.admin_announcements TO service_role;


--
-- Name: TABLE admin_emails; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.admin_emails TO service_role;


--
-- Name: TABLE ai_models; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_models TO service_role;


--
-- Name: TABLE ai_provider_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_provider_settings TO service_role;


--
-- Name: TABLE announcement_dismissals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.announcement_dismissals TO service_role;


--
-- Name: TABLE announcements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.announcements TO service_role;


--
-- Name: TABLE api_keys; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.api_keys TO service_role;


--
-- Name: TABLE artist_styles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.artist_styles TO service_role;


--
-- Name: TABLE attribution_pools; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.attribution_pools TO service_role;


--
-- Name: TABLE attribution_shares; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.attribution_shares TO service_role;


--
-- Name: TABLE audio_separations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audio_separations TO service_role;


--
-- Name: TABLE balance_transactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.balance_transactions TO service_role;


--
-- Name: TABLE beat_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.beat_purchases TO service_role;


--
-- Name: TABLE bug_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.bug_reports TO service_role;


--
-- Name: TABLE challenges; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.challenges TO service_role;


--
-- Name: TABLE chart_entries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.chart_entries TO service_role;


--
-- Name: TABLE comment_likes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.comment_likes TO service_role;


--
-- Name: TABLE comment_mentions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.comment_mentions TO service_role;


--
-- Name: TABLE comment_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.comment_reactions TO service_role;


--
-- Name: TABLE comment_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.comment_reports TO service_role;


--
-- Name: TABLE comments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.comments TO service_role;


--
-- Name: TABLE contest_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_achievements TO service_role;


--
-- Name: TABLE contest_asset_downloads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_asset_downloads TO service_role;


--
-- Name: TABLE contest_comment_likes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_comment_likes TO service_role;


--
-- Name: TABLE contest_entries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_entries TO service_role;


--
-- Name: TABLE contest_entry_comments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_entry_comments TO service_role;


--
-- Name: TABLE contest_jury; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_jury TO service_role;


--
-- Name: TABLE contest_jury_scores; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_jury_scores TO service_role;


--
-- Name: TABLE contest_leagues; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_leagues TO service_role;


--
-- Name: TABLE contest_ratings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_ratings TO service_role;


--
-- Name: TABLE contest_seasons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_seasons TO service_role;


--
-- Name: TABLE contest_user_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_user_achievements TO service_role;


--
-- Name: TABLE contest_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_votes TO service_role;


--
-- Name: TABLE contest_winners; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contest_winners TO service_role;


--
-- Name: TABLE contests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contests TO service_role;


--
-- Name: TABLE conversation_participants; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.conversation_participants TO service_role;


--
-- Name: TABLE conversations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.conversations TO service_role;


--
-- Name: TABLE copyright_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.copyright_requests TO service_role;


--
-- Name: TABLE creator_earnings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.creator_earnings TO service_role;


--
-- Name: TABLE distribution_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.distribution_logs TO service_role;


--
-- Name: TABLE distribution_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.distribution_requests TO service_role;


--
-- Name: TABLE economy_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.economy_config TO service_role;


--
-- Name: TABLE economy_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.economy_snapshots TO service_role;


--
-- Name: TABLE email_templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.email_templates TO service_role;


--
-- Name: TABLE email_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.email_verifications TO service_role;


--
-- Name: TABLE error_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.error_logs TO service_role;


--
-- Name: TABLE feature_trials; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.feature_trials TO service_role;


--
-- Name: TABLE feed_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.feed_config TO service_role;


--
-- Name: TABLE follows; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.follows TO service_role;


--
-- Name: TABLE forum_activity_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_activity_log TO service_role;


--
-- Name: TABLE forum_attachments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_attachments TO service_role;


--
-- Name: TABLE forum_automod_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_automod_settings TO service_role;


--
-- Name: TABLE forum_bookmarks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_bookmarks TO service_role;


--
-- Name: TABLE forum_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_categories TO service_role;


--
-- Name: TABLE forum_category_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_category_subscriptions TO service_role;


--
-- Name: TABLE forum_citations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_citations TO service_role;


--
-- Name: TABLE forum_content_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_content_purchases TO service_role;


--
-- Name: TABLE forum_content_quality; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_content_quality TO service_role;


--
-- Name: TABLE forum_drafts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_drafts TO service_role;


--
-- Name: TABLE forum_hub_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_hub_config TO service_role;


--
-- Name: TABLE forum_knowledge_articles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_knowledge_articles TO service_role;


--
-- Name: TABLE forum_link_previews; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_link_previews TO service_role;


--
-- Name: TABLE forum_mod_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_mod_logs TO service_role;


--
-- Name: TABLE forum_poll_options; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_poll_options TO service_role;


--
-- Name: TABLE forum_poll_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_poll_votes TO service_role;


--
-- Name: TABLE forum_polls; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_polls TO service_role;


--
-- Name: TABLE forum_post_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_post_reactions TO service_role;


--
-- Name: TABLE forum_post_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_post_votes TO service_role;


--
-- Name: TABLE forum_posts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_posts TO service_role;


--
-- Name: TABLE forum_premium_content; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_premium_content TO service_role;


--
-- Name: TABLE forum_promo_slots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_promo_slots TO service_role;


--
-- Name: TABLE forum_read_status; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_read_status TO service_role;


--
-- Name: TABLE forum_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_reports TO service_role;


--
-- Name: TABLE forum_reputation_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_reputation_config TO service_role;


--
-- Name: TABLE forum_reputation_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_reputation_log TO service_role;


--
-- Name: TABLE forum_similar_topics; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_similar_topics TO service_role;


--
-- Name: TABLE forum_staff_notes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_staff_notes TO service_role;


--
-- Name: TABLE forum_tags; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_tags TO service_role;


--
-- Name: TABLE forum_topic_boosts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topic_boosts TO service_role;


--
-- Name: TABLE forum_topic_cluster_members; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topic_cluster_members TO service_role;


--
-- Name: TABLE forum_topic_clusters; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topic_clusters TO service_role;


--
-- Name: TABLE forum_topic_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topic_subscriptions TO service_role;


--
-- Name: TABLE forum_topic_tags; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topic_tags TO service_role;


--
-- Name: TABLE forum_topics; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_topics TO service_role;


--
-- Name: TABLE forum_user_bans; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_user_bans TO service_role;


--
-- Name: TABLE forum_user_ignores; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_user_ignores TO service_role;


--
-- Name: TABLE forum_user_reads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_user_reads TO service_role;


--
-- Name: TABLE forum_user_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_user_stats TO service_role;


--
-- Name: TABLE forum_warning_appeals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_warning_appeals TO service_role;


--
-- Name: TABLE forum_warning_points; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_warning_points TO service_role;


--
-- Name: TABLE forum_warnings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.forum_warnings TO service_role;


--
-- Name: TABLE gallery_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gallery_items TO service_role;


--
-- Name: TABLE gallery_likes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gallery_likes TO service_role;


--
-- Name: TABLE generated_lyrics; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.generated_lyrics TO service_role;


--
-- Name: TABLE generation_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.generation_logs TO service_role;


--
-- Name: TABLE generation_queue; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.generation_queue TO service_role;


--
-- Name: TABLE genre_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.genre_categories TO service_role;


--
-- Name: TABLE genres; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.genres TO service_role;


--
-- Name: TABLE impersonation_action_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.impersonation_action_logs TO service_role;


--
-- Name: TABLE internal_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.internal_votes TO service_role;


--
-- Name: TABLE item_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.item_purchases TO service_role;


--
-- Name: TABLE legal_documents; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.legal_documents TO service_role;


--
-- Name: TABLE lyrics; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lyrics TO service_role;


--
-- Name: TABLE lyrics_deposits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lyrics_deposits TO service_role;


--
-- Name: TABLE lyrics_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lyrics_items TO service_role;


--
-- Name: TABLE maintenance_whitelist; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.maintenance_whitelist TO service_role;


--
-- Name: TABLE message_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.message_reactions TO service_role;


--
-- Name: TABLE messages; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.messages TO service_role;


--
-- Name: TABLE moderator_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.moderator_permissions TO service_role;


--
-- Name: TABLE moderator_presets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.moderator_presets TO service_role;


--
-- Name: TABLE weighted_votes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.weighted_votes TO anon;
GRANT ALL ON TABLE public.weighted_votes TO service_role;
GRANT SELECT ON TABLE public.weighted_votes TO authenticated;


--
-- Name: TABLE mv_voting_live; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.mv_voting_live TO service_role;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.notifications TO service_role;


--
-- Name: TABLE payment_callbacks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payment_callbacks TO service_role;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payments TO service_role;


--
-- Name: TABLE payout_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payout_requests TO service_role;


--
-- Name: TABLE performance_alerts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.performance_alerts TO service_role;


--
-- Name: TABLE permission_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.permission_categories TO service_role;


--
-- Name: TABLE personas; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.personas TO service_role;


--
-- Name: TABLE playlist_tracks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.playlist_tracks TO service_role;


--
-- Name: TABLE playlists; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.playlists TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE user_roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_roles TO service_role;


--
-- Name: TABLE profiles_public; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles_public TO service_role;


--
-- Name: TABLE promo_videos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.promo_videos TO service_role;


--
-- Name: TABLE prompt_purchases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.prompt_purchases TO service_role;


--
-- Name: TABLE prompts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.prompts TO service_role;


--
-- Name: TABLE qa_bounties; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_bounties TO service_role;


--
-- Name: TABLE qa_comments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_comments TO service_role;


--
-- Name: TABLE qa_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_config TO service_role;


--
-- Name: TABLE qa_tester_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_tester_stats TO service_role;


--
-- Name: TABLE qa_tickets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_tickets TO service_role;


--
-- Name: TABLE qa_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.qa_votes TO service_role;


--
-- Name: TABLE radio_ad_placements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_ad_placements TO service_role;


--
-- Name: TABLE radio_bids; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_bids TO service_role;


--
-- Name: TABLE radio_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_config TO service_role;


--
-- Name: TABLE radio_listeners; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_listeners TO service_role;


--
-- Name: TABLE radio_listens; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_listens TO service_role;


--
-- Name: TABLE radio_predictions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_predictions TO service_role;


--
-- Name: TABLE radio_queue; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_queue TO service_role;


--
-- Name: TABLE radio_schedule; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_schedule TO service_role;


--
-- Name: TABLE radio_slots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.radio_slots TO service_role;


--
-- Name: TABLE referral_codes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.referral_codes TO service_role;


--
-- Name: TABLE referral_rewards; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.referral_rewards TO service_role;


--
-- Name: TABLE referral_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.referral_settings TO service_role;


--
-- Name: TABLE referral_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.referral_stats TO service_role;


--
-- Name: TABLE referrals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.referrals TO service_role;


--
-- Name: TABLE reposts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reposts TO service_role;


--
-- Name: TABLE reputation_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reputation_events TO service_role;


--
-- Name: TABLE reputation_tiers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reputation_tiers TO service_role;


--
-- Name: TABLE role_change_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.role_change_logs TO service_role;


--
-- Name: TABLE role_invitation_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.role_invitation_permissions TO service_role;


--
-- Name: TABLE role_invitations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.role_invitations TO service_role;


--
-- Name: TABLE security_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.security_audit_log TO service_role;


--
-- Name: TABLE seller_earnings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_earnings TO service_role;


--
-- Name: TABLE seo_ai_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seo_ai_config TO service_role;


--
-- Name: TABLE seo_metadata; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seo_metadata TO service_role;


--
-- Name: TABLE seo_robots_rules; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seo_robots_rules TO service_role;


--
-- Name: TABLE settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.settings TO service_role;


--
-- Name: TABLE store_beats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.store_beats TO service_role;


--
-- Name: TABLE store_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.store_items TO service_role;


--
-- Name: TABLE subscription_plans; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.subscription_plans TO service_role;


--
-- Name: TABLE support_messages; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.support_messages TO service_role;


--
-- Name: TABLE support_tickets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.support_tickets TO service_role;


--
-- Name: TABLE system_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.system_settings TO service_role;


--
-- Name: TABLE templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.templates TO service_role;


--
-- Name: TABLE ticket_messages; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ticket_messages TO service_role;


--
-- Name: TABLE track_addons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_addons TO service_role;


--
-- Name: TABLE track_bookmarks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_bookmarks TO service_role;


--
-- Name: TABLE track_comments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_comments TO service_role;


--
-- Name: TABLE track_daily_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_daily_stats TO service_role;


--
-- Name: TABLE track_deposits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_deposits TO service_role;


--
-- Name: TABLE track_feed_scores; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_feed_scores TO service_role;


--
-- Name: TABLE track_health_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_health_reports TO service_role;


--
-- Name: TABLE track_likes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_likes TO service_role;


--
-- Name: TABLE track_promotions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_promotions TO service_role;


--
-- Name: TABLE track_quality_scores; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_quality_scores TO service_role;


--
-- Name: TABLE track_reactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_reactions TO service_role;


--
-- Name: TABLE track_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_reports TO service_role;


--
-- Name: TABLE track_votes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.track_votes TO service_role;


--
-- Name: TABLE user_achievements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_achievements TO service_role;


--
-- Name: TABLE user_blocks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_blocks TO service_role;


--
-- Name: TABLE user_challenges; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_challenges TO service_role;


--
-- Name: TABLE user_follows; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_follows TO service_role;


--
-- Name: TABLE user_prompts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_prompts TO service_role;


--
-- Name: TABLE user_streaks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_streaks TO service_role;


--
-- Name: TABLE user_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_subscriptions TO service_role;


--
-- Name: TABLE verification_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.verification_requests TO service_role;


--
-- Name: TABLE vocal_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vocal_types TO service_role;


--
-- Name: TABLE vote_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vote_audit_log TO service_role;


--
-- Name: TABLE vote_combos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vote_combos TO service_role;


--
-- Name: TABLE voter_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.voter_profiles TO service_role;


--
-- Name: TABLE voting_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.voting_snapshots TO service_role;


--
-- Name: TABLE xp_event_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.xp_event_config TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE aimuza IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict VGnYHVuVeDI1rawLSZpuv4O7odj7hcIAg9tfveOc2s0bTv2JFwqO7ZExYCWsiNP

