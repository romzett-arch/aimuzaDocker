-- Fix get_radio_stats to handle missing tables gracefully
-- This makes the function work even if some tables don't exist yet

CREATE OR REPLACE FUNCTION public.get_radio_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- Grant permissions
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_stats() TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_stats() TO anon;
  END IF;
END $$;
