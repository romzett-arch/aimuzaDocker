-- Preserve radio XP for signed-in listeners after removing the arena vote bridge.
CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID, p_track_id UUID, p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER, p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL, p_ip_hash TEXT DEFAULT NULL,
  p_is_afk_verified BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config JSONB; v_listen_percent NUMERIC; v_xp_earned INTEGER := 0;
  v_xp_today INTEGER; v_daily_cap INTEGER; v_min_percent NUMERIC;
  v_xp_per_listen NUMERIC; v_caller UUID; v_previous_role TEXT;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL OR v_caller <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tracks WHERE id = p_track_id AND status = 'completed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'track_not_available');
  END IF;

  SELECT value INTO v_config FROM public.radio_config WHERE key = 'listen_to_earn';
  v_daily_cap := COALESCE((v_config->>'daily_cap')::INTEGER, 100);
  v_min_percent := COALESCE((v_config->>'min_listen_percent')::NUMERIC, 60);
  v_xp_per_listen := COALESCE((v_config->>'xp_per_listen')::NUMERIC, 2);
  p_track_duration_sec := GREATEST(p_track_duration_sec, 1);
  v_listen_percent := LEAST(100, GREATEST(0, p_listen_duration_sec::NUMERIC / p_track_duration_sec * 100));

  PERFORM pg_advisory_xact_lock(hashtextextended('radio_xp:' || v_caller::text, 0));

  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_listen_percent >= v_min_percent AND v_xp_today < v_daily_cap THEN
    v_xp_earned := LEAST(
      GREATEST(1, round(v_xp_per_listen * v_listen_percent / 100)::INTEGER),
      v_daily_cap - v_xp_today
    );
  END IF;

  IF v_xp_earned > 0 THEN
    -- Only this award uses the internal writer role. The caller and amount were checked above.
    v_previous_role := current_setting('request.jwt.claim.role', true);
    PERFORM set_config('request.jwt.claim.role', 'service_role', true);
    v_xp_earned := public.fn_add_xp(v_caller, v_xp_earned, 'music', false);
    PERFORM set_config('request.jwt.claim.role', COALESCE(v_previous_role, ''), true);
  END IF;

  INSERT INTO public.radio_listens(user_id, track_id, session_id, listen_duration_sec,
    track_duration_sec, listen_percent, xp_earned, reaction, ip_hash, is_afk_verified)
  VALUES (p_user_id, p_track_id, p_session_id, p_listen_duration_sec,
    p_track_duration_sec, v_listen_percent, v_xp_earned, p_reaction, p_ip_hash, p_is_afk_verified);

  v_xp_today := v_xp_today + v_xp_earned;

  RETURN jsonb_build_object('ok', true, 'xp_earned', v_xp_earned,
    'listen_percent', v_listen_percent, 'xp_today', v_xp_today,
    'daily_cap', v_daily_cap,
    'listens_today', (SELECT count(*) FROM public.radio_listens WHERE user_id=p_user_id AND created_at>=CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap);
END;
$$;
