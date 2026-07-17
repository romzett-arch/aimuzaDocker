-- The generic track protection trigger must not revert counters maintained by
-- the trusted weighted-vote aggregate function.
BEGIN;

CREATE OR REPLACE FUNCTION public.refresh_track_voting_totals(
  p_track_id uuid,
  p_round_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_likes numeric;
  v_dislikes numeric;
  v_like_count integer;
  v_dislike_count integer;
  v_previous_bypass text;
BEGIN
  SELECT
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'like' AND revoked_at IS NULL), 0),
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'dislike' AND revoked_at IS NULL), 0),
    COUNT(*) FILTER (WHERE vote_type = 'like' AND revoked_at IS NULL)::integer,
    COUNT(*) FILTER (WHERE vote_type = 'dislike' AND revoked_at IS NULL)::integer
  INTO v_likes, v_dislikes, v_like_count, v_dislike_count
  FROM public.weighted_votes
  WHERE track_id = p_track_id AND voting_round_id = p_round_id;

  v_previous_bypass := current_setting('app.bypass_track_protection', true);
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  UPDATE public.tracks
  SET weighted_likes_sum = v_likes,
      weighted_dislikes_sum = v_dislikes,
      voting_likes_count = v_like_count,
      voting_dislikes_count = v_dislike_count
  WHERE id = p_track_id AND voting_round_id = p_round_id;

  PERFORM set_config('app.bypass_track_protection', COALESCE(v_previous_bypass, ''), true);
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_track_voting_totals(uuid, uuid) FROM PUBLIC, anon, authenticated;

COMMIT;
