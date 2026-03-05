-- =============================================================
-- RADIO → ARENA BRIDGE
-- Лайк в Радио (like/love) при listen_percent >= 50% и не AFK
-- создаёт weighted_vote с raw_weight=0.7 для чарта Арены.
-- =============================================================

-- Drop old 7-param version before creating 8-param version
DROP FUNCTION IF EXISTS public.radio_award_listen_xp(UUID, UUID, INTEGER, INTEGER, TEXT, TEXT, TEXT);

-- 1. cast_radio_vote_for_arena — внутренняя функция для вставки голоса из Радио
-- Вызывается из radio_award_listen_xp при reaction IN ('like','love')
CREATE OR REPLACE FUNCTION public.cast_radio_vote_for_arena(
  p_user_id UUID,
  p_track_id UUID,
  p_listen_duration_sec INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- 2. Обновить radio_award_listen_xp: добавить p_is_afk_verified, вызов моста, arena_vote_cast в результат
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
BEGIN
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
    IF v_xp_earned < 1 THEN
      v_xp_earned := 0;
    END IF;
  END IF;

  INSERT INTO public.radio_listens (
    user_id, track_id, session_id, listen_duration_sec, track_duration_sec,
    listen_percent, xp_earned, reaction, ip_hash, is_afk_verified
  ) VALUES (
    p_user_id, p_track_id, p_session_id, p_listen_duration_sec, p_track_duration_sec,
    v_listen_percent, v_xp_earned, p_reaction, p_ip_hash, p_is_afk_verified
  );

  -- RADIO → ARENA: при like/love, listen_percent >= 50%, не AFK — засчитать голос в чарт
  IF p_reaction IN ('like', 'love')
     AND v_listen_percent >= 50
     AND p_is_afk_verified = TRUE
  THEN
    v_arena_vote_cast := cast_radio_vote_for_arena(p_user_id, p_track_id, p_listen_duration_sec);
  END IF;

  IF v_xp_earned > 0 THEN
    PERFORM public.fn_add_xp(p_user_id, v_xp_earned, 'music', false);
  END IF;

  v_xp_today := v_xp_today + v_xp_earned;

  v_result := jsonb_build_object(
    'ok', true,
    'xp_earned', v_xp_earned,
    'listen_percent', v_listen_percent,
    'xp_today', v_xp_today,
    'daily_cap', v_daily_cap,
    'listens_today', (SELECT COUNT(*) FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap,
    'arena_vote_cast', v_arena_vote_cast
  );

  RETURN v_result;
END;
$$;

-- Обновить GRANT для новой сигнатуры (8 параметров)
GRANT EXECUTE ON FUNCTION public.radio_award_listen_xp(UUID, UUID, INTEGER, INTEGER, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;
