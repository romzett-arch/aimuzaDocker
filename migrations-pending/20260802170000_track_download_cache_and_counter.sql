CREATE OR REPLACE FUNCTION public.increment_track_download_count(p_track_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_downloads_count bigint;
BEGIN
  UPDATE public.tracks
  SET downloads_count = COALESCE(downloads_count, 0) + 1
  WHERE id = p_track_id
  RETURNING downloads_count INTO v_downloads_count;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Track not found';
  END IF;

  RETURN v_downloads_count;
END;
$$;

REVOKE ALL ON FUNCTION public.increment_track_download_count(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_track_download_count(uuid) TO service_role;
