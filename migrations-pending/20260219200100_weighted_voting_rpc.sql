-- =============================================================
-- ULTIMATE VOTING ARCHITECTURE — Phase 2: RPC Functions
-- cast_weighted_vote, assess_vote_fraud, get_voting_live_stats, etc.
-- =============================================================

-- Add xp_for_vote setting if not exists
INSERT INTO public.settings (key, value, description) VALUES
  ('xp_for_vote', '2', 'XP за голос за трек')
ON CONFLICT (key) DO NOTHING;

-- =============================================================
-- assess_vote_fraud — внутренняя функция, возвращает fraud_multiplier 0.0-1.0
-- =============================================================
CREATE OR REPLACE FUNCTION public.assess_vote_fraud(
  p_user_id UUID,
  p_track_id UUID,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip INET DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  -- 1. Возраст аккаунта < 24ч → 0.3
  SELECT EXTRACT(EPOCH FROM (now() - created_at)) / 3600 INTO v_account_age_hours
  FROM auth.users WHERE id = p_user_id;
  IF v_account_age_hours < 24 THEN
    v_multiplier := v_multiplier * 0.3;
  END IF;

  -- 2. Самоголосование
  SELECT user_id INTO v_track_owner FROM tracks WHERE id = p_track_id;
  IF p_user_id = v_track_owner THEN
    RETURN 0.0;
  END IF;

  -- 3. Fingerprint collision — тот же fingerprint голосовал за этот трек
  IF p_fingerprint IS NOT NULL AND length(p_fingerprint) > 0 THEN
    SELECT EXISTS(
      SELECT 1 FROM weighted_votes
      WHERE track_id = p_track_id AND fingerprint_hash = p_fingerprint AND user_id != p_user_id
    ) INTO v_fingerprint_match;
    IF v_fingerprint_match THEN
      RETURN 0.0;
    END IF;
  END IF;

  -- 4. IP clustering — более 3 голосов с одного IP за этот трек
  IF p_ip IS NOT NULL THEN
    SELECT COUNT(*) INTO v_ip_votes_count
    FROM weighted_votes
    WHERE track_id = p_track_id AND ip_address = p_ip;
    IF v_ip_votes_count >= 3 THEN
      v_multiplier := v_multiplier * 0.1;
    END IF;
  END IF;

  -- 5. Velocity check — более 10 голосов за последние 5 минут
  SELECT COUNT(*) INTO v_velocity_count
  FROM weighted_votes
  WHERE user_id = p_user_id AND created_at > now() - interval '5 minutes';
  IF v_velocity_count >= 10 THEN
    v_multiplier := v_multiplier * 0.2;
  END IF;

  -- 6. Pattern detection — все голоса за одного автора (упрощённо: >80% голосов за треки одного автора)
  SELECT COUNT(*) INTO v_same_author_count
  FROM weighted_votes wv
  JOIN tracks t ON t.id = wv.track_id
  WHERE wv.user_id = p_user_id AND t.user_id = v_track_owner;
  IF v_same_author_count >= 5 AND (SELECT COUNT(*) FROM weighted_votes WHERE user_id = p_user_id) <= v_same_author_count * 1.2 THEN
    v_multiplier := v_multiplier * 0.3;
  END IF;

  -- 7. Referral ring — пользователь и автор связаны реферальной цепочкой
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

-- =============================================================
-- get_voting_live_stats — batch-получение статистики для polling
-- =============================================================
CREATE OR REPLACE FUNCTION public.get_voting_live_stats(p_track_ids UUID[])
RETURNS TABLE(
  track_id UUID,
  weighted_likes NUMERIC,
  weighted_dislikes NUMERIC,
  total_voters BIGINT,
  like_count BIGINT,
  dislike_count BIGINT,
  approval_rate NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- get_voter_profile — профиль голосующего
-- =============================================================
CREATE OR REPLACE FUNCTION public.get_voter_profile(p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- revoke_vote — отмена голоса
-- =============================================================
CREATE OR REPLACE FUNCTION public.revoke_vote(p_track_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- take_voting_snapshot — снапшот для графиков
-- =============================================================
CREATE OR REPLACE FUNCTION public.take_voting_snapshot(p_track_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- calculate_chart_scores — пересчёт чарта (вызывается из cron)
-- =============================================================
CREATE OR REPLACE FUNCTION public.calculate_chart_scores()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- aggregate_votes_to_tracks — агрегация weighted_votes в tracks (cron 5 сек)
-- =============================================================
CREATE OR REPLACE FUNCTION public.aggregate_votes_to_tracks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INTEGER := 0;
BEGIN
  WITH agg AS (
    SELECT
      wv.track_id,
      SUM(CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.final_weight ELSE 0 END) AS likes_sum,
      SUM(CASE WHEN wv.vote_type = 'dislike' THEN wv.final_weight ELSE 0 END) AS dislikes_sum
    FROM weighted_votes wv
    GROUP BY wv.track_id
  )
  UPDATE tracks t SET
    weighted_likes_sum = agg.likes_sum,
    weighted_dislikes_sum = agg.dislikes_sum
  FROM agg
  WHERE t.id = agg.track_id
  AND (COALESCE(t.weighted_likes_sum, 0) != agg.likes_sum OR COALESCE(t.weighted_dislikes_sum, 0) != agg.dislikes_sum);

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;

-- =============================================================
-- update_voter_ranks — пересчёт рангов (cron)
-- Scout 0-30%, Curator 30-50%, Tastemaker 50-70%, Oracle 70%+ и 50+ голосов
-- =============================================================
CREATE OR REPLACE FUNCTION public.update_voter_ranks()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- admin_review_flagged_votes — подозрительные голоса по треку
-- =============================================================
CREATE OR REPLACE FUNCTION public.admin_review_flagged_votes(p_track_id UUID)
RETURNS TABLE(
  vote_id UUID,
  user_id UUID,
  vote_type TEXT,
  final_weight NUMERIC,
  fraud_multiplier NUMERIC,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- =============================================================
-- cast_weighted_vote — основная функция голосования (fixed)
-- =============================================================
CREATE OR REPLACE FUNCTION public.cast_weighted_vote(
  p_track_id UUID,
  p_vote_type TEXT,
  p_fingerprint TEXT DEFAULT NULL,
  p_context JSONB DEFAULT NULL,
  p_ip INET DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  v_voter_rank TEXT := 'scout';
  v_xp_earned INTEGER := 0;
  v_combo_window_hours INTEGER;
  v_existing_vote RECORD;
  v_has_existing_vote BOOLEAN := false;
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
