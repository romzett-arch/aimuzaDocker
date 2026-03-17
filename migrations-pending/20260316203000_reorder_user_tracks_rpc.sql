-- Батчевое обновление порядка треков одним RPC-вызовом.
-- Убирает шквал PATCH /rest/v1/tracks при drag-and-drop в "Мои треки".

CREATE OR REPLACE FUNCTION public.reorder_user_tracks(
  p_track_ids UUID[],
  p_user_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_updated_count INTEGER;
  v_expected_count INTEGER;
BEGIN
  v_caller := auth.uid();

  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;

  v_expected_count := COALESCE(array_length(p_track_ids, 1), 0);
  IF v_expected_count = 0 THEN
    RETURN;
  END IF;

  IF v_caller <> p_user_id AND NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_track_ids) AS track_id
    GROUP BY track_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Track list contains duplicates';
  END IF;

  WITH ordered_tracks AS (
    SELECT
      track_id,
      ordinality::INTEGER AS new_position
    FROM unnest(p_track_ids) WITH ORDINALITY AS t(track_id, ordinality)
  ),
  updated_tracks AS (
    UPDATE public.tracks AS tr
    SET position = ordered_tracks.new_position
    FROM ordered_tracks
    WHERE tr.id = ordered_tracks.track_id
      AND tr.user_id = p_user_id
    RETURNING tr.id
  )
  SELECT COUNT(*) INTO v_updated_count
  FROM updated_tracks;

  IF v_updated_count <> v_expected_count THEN
    RAISE EXCEPTION 'Some tracks were not updated';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reorder_user_tracks(UUID[], UUID) TO authenticated;
