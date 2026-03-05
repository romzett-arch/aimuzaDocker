-- =====================================================
-- Analytics tracking fix: likes_count + track_daily_stats
-- 1. Allow RPC to update likes_count (bypass security trigger)
-- 2. Add record_track_like_update RPC for likes
-- =====================================================

-- 1. Modify protect_track_critical_fields to allow updates from trusted RPC
CREATE OR REPLACE FUNCTION public.protect_track_critical_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_sub text;
  v_bypass text;
BEGIN
  -- Allow updates from trusted RPC (record_track_like_update)
  v_bypass := current_setting('app.bypass_track_protection', true);
  IF v_bypass = 'true' THEN
    RETURN NEW;
  END IF;

  v_sub := current_setting('request.jwt.claim.sub', true);
  IF v_sub IS NULL OR v_sub = '' THEN
    RETURN NEW;
  END IF;

  IF public.is_admin(v_sub::uuid) THEN
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

-- 2. Fix record_track_play: also needs bypass for plays_count
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

-- 3. RPC: update tracks.likes_count and track_daily_stats.likes_count
-- Call after insert/delete in track_likes. p_delta: +1 for like, -1 for unlike.
CREATE OR REPLACE FUNCTION public.record_track_like_update(p_track_id UUID, p_delta INTEGER)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
