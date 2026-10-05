ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS exclusive_distribution_accepted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS exclusive_distribution_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS exclusive_distribution_terms_version text;

ALTER TABLE public.tracks
  DROP CONSTRAINT IF EXISTS tracks_uploaded_exclusive_distribution_consent_check;

ALTER TABLE public.tracks
  ADD CONSTRAINT tracks_uploaded_exclusive_distribution_consent_check
  CHECK (
    source_type <> 'uploaded'
    OR NOT COALESCE(exclusive_distribution_accepted, false)
    OR (
      exclusive_distribution_accepted_at IS NOT NULL
      AND NULLIF(btrim(exclusive_distribution_terms_version), '') IS NOT NULL
    )
  );

CREATE OR REPLACE FUNCTION public.submit_track_for_moderation(
  p_track_id uuid,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL
)
RETURNS public.tracks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_track public.tracks%ROWTYPE;
  v_title text;
  v_from_status text;
  v_previous_bypass text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден'; END IF;
  IF v_track.moderation_status = 'pending' THEN RETURN v_track; END IF;
  IF COALESCE(v_track.moderation_status, 'none') NOT IN ('none', 'rejected') THEN RAISE EXCEPTION 'Трек нельзя отправить на модерацию из текущего статуса'; END IF;
  IF COALESCE(btrim(v_track.audio_url), '') = '' THEN RAISE EXCEPTION 'У трека отсутствует аудиофайл'; END IF;
  IF v_track.source_type = 'uploaded' AND (NOT COALESCE(v_track.exclusive_distribution_accepted, false) OR v_track.exclusive_distribution_accepted_at IS NULL OR NULLIF(btrim(v_track.exclusive_distribution_terms_version), '') IS NULL) THEN
    RAISE EXCEPTION 'Необходимо принять условия эксклюзивной дистрибуции';
  END IF;
  v_title := COALESCE(NULLIF(btrim(p_title), ''), NULLIF(btrim(v_track.title), ''));
  IF v_title IS NULL THEN RAISE EXCEPTION 'Укажите название трека'; END IF;
  v_from_status := COALESCE(v_track.moderation_status, 'none');
  v_previous_bypass := current_setting('app.bypass_track_protection', true);
  PERFORM set_config('app.bypass_track_protection', 'true', true);
  UPDATE public.tracks SET title = v_title, description = CASE WHEN p_description IS NULL THEN description ELSE NULLIF(btrim(p_description), '') END, status = 'pending', moderation_status = 'pending', is_public = false, moderation_rejection_reason = NULL, moderation_notes = NULL, moderation_reviewed_at = NULL, moderation_reviewed_by = NULL, updated_at = now() WHERE id = p_track_id RETURNING * INTO v_track;
  INSERT INTO public.moderation_events (track_id, track_user_id, actor_id, action, from_status, to_status, metadata)
  VALUES (v_track.id, v_track.user_id, v_user_id, 'submitted', v_from_status, 'pending', jsonb_build_object('exclusive_distribution_accepted', v_track.exclusive_distribution_accepted, 'exclusive_distribution_accepted_at', v_track.exclusive_distribution_accepted_at, 'exclusive_distribution_terms_version', v_track.exclusive_distribution_terms_version));
  PERFORM set_config('app.bypass_track_protection', COALESCE(v_previous_bypass, 'false'), true);
  RETURN v_track;
END;
$$;
