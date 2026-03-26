CREATE OR REPLACE FUNCTION public.record_track_play(p_track_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

GRANT EXECUTE ON FUNCTION public.record_track_play(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_track_play(UUID) TO anon;
