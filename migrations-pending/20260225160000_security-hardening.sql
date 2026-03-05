-- =====================================================
-- Security Hardening Migration
-- Phase 2: DB-level protection for all identified vulns
-- =====================================================

-- 2.1 Protect critical tracks fields via trigger
CREATE OR REPLACE FUNCTION public.protect_track_critical_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('request.jwt.claim.sub', true) IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_admin(
    (current_setting('request.jwt.claim.sub', true))::uuid
  ) THEN
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

DROP TRIGGER IF EXISTS trg_protect_track_critical_fields ON public.tracks;
CREATE TRIGGER trg_protect_track_critical_fields
  BEFORE UPDATE ON public.tracks
  FOR EACH ROW EXECUTE FUNCTION public.protect_track_critical_fields();


-- 2.2 fn_add_xp — admin_override requires is_admin, p_user_id must be auth.uid() for non-admin
CREATE OR REPLACE FUNCTION public.fn_add_xp(
  p_user_id UUID,
  p_amount NUMERIC,
  p_category TEXT DEFAULT 'forum',
  p_admin_override BOOLEAN DEFAULT false
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


-- 2.3 Radio IDOR fixes — add auth.uid() checks
CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID,
  p_slot_id UUID,
  p_track_id UUID,
  p_amount INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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
$fn$;


CREATE OR REPLACE FUNCTION public.radio_place_prediction(
  p_user_id UUID,
  p_track_id UUID,
  p_bet_amount INTEGER,
  p_predicted_hit BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


CREATE OR REPLACE FUNCTION public.radio_skip_ad(
  p_user_id UUID,
  p_ad_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID,
  p_track_id UUID,
  p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER,
  p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_hash TEXT DEFAULT NULL,
  p_is_afk_verified BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


-- 2.4 radio_queue RLS — restrict to service_role only
DROP POLICY IF EXISTS "Service can manage radio_queue" ON public.radio_queue;
CREATE POLICY "Service can manage radio_queue" ON public.radio_queue
  FOR ALL TO service_role USING (true) WITH CHECK (true);


-- 2.5 Voting functions — authorization checks

CREATE OR REPLACE FUNCTION public.send_track_to_voting(
  p_track_id UUID,
  p_duration_days INTEGER DEFAULT NULL,
  p_voting_type TEXT DEFAULT 'public'
)
RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


CREATE OR REPLACE FUNCTION public.resolve_track_voting(
  p_track_id UUID,
  p_manual_result TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


-- 2.6 DROP superseded IDOR-prone functions
DROP FUNCTION IF EXISTS public.process_beat_purchase(UUID, UUID);
DROP FUNCTION IF EXISTS public.process_prompt_purchase(UUID, UUID);


-- 2.7 balance_transactions INSERT — restrict to service_role
DO $$
BEGIN
  DROP POLICY IF EXISTS "Service role can insert transactions" ON public.balance_transactions;
  CREATE POLICY "Service role can insert transactions"
    ON public.balance_transactions FOR INSERT TO service_role WITH CHECK (true);
EXCEPTION WHEN undefined_table THEN NULL;
END $$;


-- 2.8 SECURITY DEFINER search_path fixes for functions that were missing it
ALTER FUNCTION public.fn_add_xp(UUID, NUMERIC, TEXT, BOOLEAN) SET search_path = public;
DO $$
BEGIN
  ALTER FUNCTION public.update_track_vote_counts() SET search_path = public;
EXCEPTION WHEN undefined_function THEN NULL;
END $$;


-- 2.9 REVOKE dangerous functions from authenticated
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.radio_resolve_predictions() FROM authenticated;
  REVOKE EXECUTE ON FUNCTION public.cleanup_old_logs() FROM authenticated;
EXCEPTION WHEN undefined_function THEN NULL;
END $$;


-- 2.10 CHECK constraint on balance
DO $$
BEGIN
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_balance_non_negative CHECK (balance >= 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- 2.11 Atomic debit_balance RPC
CREATE OR REPLACE FUNCTION public.debit_balance(
  p_user_id UUID,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'debit'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

GRANT EXECUTE ON FUNCTION public.debit_balance(UUID, INTEGER, TEXT) TO authenticated;


-- 2.12 XP deduplication in triggers
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


CREATE OR REPLACE FUNCTION public.fn_xp_on_follow()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


CREATE OR REPLACE FUNCTION public.fn_xp_on_comment_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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


-- 2.13 user_roles INSERT — remove direct time-window policy, keep only invitation-based
DROP POLICY IF EXISTS "Users can receive role via invitation" ON public.user_roles;
CREATE POLICY "Users can receive role via invitation" ON public.user_roles
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM role_invitations ri
      WHERE ri.user_id = user_roles.user_id
        AND ri.role = user_roles.role
        AND ri.status = 'accepted'
        AND ri.responded_at > NOW() - INTERVAL '1 minute'
    )
    OR is_admin(auth.uid())
  );
