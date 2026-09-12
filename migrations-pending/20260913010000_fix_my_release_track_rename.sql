-- Rename generated releases atomically and keep release-package metadata in sync.
CREATE OR REPLACE FUNCTION public.rename_my_release_track(
  p_track_id UUID,
  p_title TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_title TEXT := btrim(COALESCE(p_title, ''));
  v_updated_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;

  IF v_title = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Название не может быть пустым');
  END IF;

  IF char_length(v_title) > 200 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Название не должно превышать 200 символов');
  END IF;

  UPDATE public.tracks
  SET title = v_title
  WHERE id = p_track_id
    AND user_id = v_user_id
    AND COALESCE(is_in_my_releases, false) = true
  RETURNING id INTO v_updated_id;

  IF v_updated_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Релиз не найден или не принадлежит вам');
  END IF;

  UPDATE public.release_packages
  SET requested_title = v_title,
      updated_at = now()
  WHERE track_id = p_track_id
    AND user_id = v_user_id;

  RETURN jsonb_build_object('success', true, 'track_id', v_updated_id, 'title', v_title);
END;
$$;

REVOKE ALL ON FUNCTION public.rename_my_release_track(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rename_my_release_track(UUID, TEXT) TO authenticated;
