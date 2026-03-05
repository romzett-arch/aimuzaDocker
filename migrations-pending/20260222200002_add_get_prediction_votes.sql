-- get_prediction_votes: returns aggregated hit/no-hit vote counts for a track
-- Needed because RLS on radio_predictions only allows reading own rows

CREATE OR REPLACE FUNCTION public.get_prediction_votes(p_track_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hit INTEGER;
  v_no_hit INTEGER;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE predicted_hit = TRUE),
    COUNT(*) FILTER (WHERE predicted_hit = FALSE)
  INTO v_hit, v_no_hit
  FROM public.radio_predictions
  WHERE track_id = p_track_id AND status = 'pending';

  RETURN jsonb_build_object(
    'hit', COALESCE(v_hit, 0),
    'no_hit', COALESCE(v_no_hit, 0),
    'total', COALESCE(v_hit, 0) + COALESCE(v_no_hit, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_prediction_votes(UUID) TO authenticated;
