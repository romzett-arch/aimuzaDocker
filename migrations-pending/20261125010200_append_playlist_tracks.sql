CREATE OR REPLACE FUNCTION public.append_playlist_tracks(p_playlist_id uuid, p_track_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_owner uuid := auth.uid();
  v_added integer;
  v_existing integer;
  v_unavailable integer;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('error', 'auth_required');
  END IF;
  IF COALESCE(cardinality(p_track_ids), 0) NOT BETWEEN 1 AND 1000 OR array_position(p_track_ids, NULL::uuid) IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'invalid_tracks');
  END IF;

  PERFORM 1 FROM public.playlists WHERE id = p_playlist_id AND user_id = v_owner FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found');
  END IF;

  WITH requested AS (
    SELECT id, min(ord) AS ord FROM unnest(p_track_ids) WITH ORDINALITY AS t(id, ord) GROUP BY id
  ), ready AS (
    SELECT requested.id, requested.ord FROM requested JOIN public.tracks AS t ON t.id = requested.id
    WHERE t.status = 'completed' AND NULLIF(btrim(t.audio_url), '') IS NOT NULL
      AND (t.user_id = v_owner OR t.is_public IS TRUE)
  ), remaining AS (
    SELECT ready.id, row_number() OVER (ORDER BY ready.ord) AS offset_by FROM ready
    WHERE NOT EXISTS (
      SELECT 1 FROM public.playlist_tracks WHERE playlist_id = p_playlist_id AND track_id = ready.id
    )
  ), last_position AS (
    SELECT COALESCE(max(position), -1) AS pos FROM public.playlist_tracks WHERE playlist_id = p_playlist_id
  ), inserted AS (
    INSERT INTO public.playlist_tracks (playlist_id, track_id, position)
    SELECT p_playlist_id, remaining.id, last_position.pos + remaining.offset_by FROM remaining CROSS JOIN last_position
    ORDER BY remaining.offset_by
    ON CONFLICT (playlist_id, track_id) DO NOTHING
    RETURNING track_id
  )
  SELECT (SELECT count(*) FROM inserted),
         (SELECT count(*) FROM ready) - (SELECT count(*) FROM inserted),
         (SELECT count(*) FROM requested) - (SELECT count(*) FROM ready)
  INTO v_added, v_existing, v_unavailable;

  RETURN jsonb_build_object('added', v_added, 'existing', v_existing, 'unavailable', v_unavailable);
END;
$$;

REVOKE ALL ON FUNCTION public.append_playlist_tracks(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.append_playlist_tracks(uuid, uuid[]) TO authenticated;
