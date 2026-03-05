-- =====================================================
-- Fix: allow moderation approval to actually update tracks
-- The protect_track_critical_fields trigger only allowed is_admin(),
-- but content moderation can be done by users with has_permission('moderation').
-- This caused the update to "succeed" (no error) but the trigger reverted
-- moderation_status, so the track stayed in moderation.
-- Also: use auth.uid() instead of request.jwt.claim.sub for reliability.
-- =====================================================

CREATE OR REPLACE FUNCTION public.protect_track_critical_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
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
