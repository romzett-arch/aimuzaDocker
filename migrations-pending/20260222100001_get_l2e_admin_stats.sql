-- RPC for L2E admin stats (bypasses RLS on radio_listens)
CREATE OR REPLACE FUNCTION public.get_l2e_admin_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.get_l2e_admin_stats() TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT EXECUTE ON FUNCTION public.get_l2e_admin_stats() TO anon;
  END IF;
END $$;
