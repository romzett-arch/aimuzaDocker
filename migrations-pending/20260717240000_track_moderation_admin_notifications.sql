CREATE OR REPLACE FUNCTION public.notify_staff_track_moderation_submission()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_artist_name text;
BEGIN
  IF NEW.moderation_status IS DISTINCT FROM 'pending' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.moderation_status IS NOT DISTINCT FROM 'pending' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(btrim(profile_row.display_name), ''), NULLIF(btrim(profile_row.username), ''), 'Пользователь')
  INTO v_artist_name
  FROM public.profiles profile_row
  WHERE profile_row.user_id = NEW.user_id
  ORDER BY profile_row.created_at ASC
  LIMIT 1;

  v_artist_name := COALESCE(v_artist_name, 'Пользователь');

  INSERT INTO public.notifications (
    user_id,
    type,
    title,
    message,
    actor_id,
    target_type,
    target_id,
    link,
    metadata
  )
  SELECT DISTINCT
    role_row.user_id,
    'new_track_moderation',
    'Новый трек на модерации',
    v_artist_name || ' отправил трек «' || COALESCE(NULLIF(btrim(NEW.title), ''), 'Без названия') || '».',
    NEW.user_id,
    'track',
    NEW.id,
    '/admin/moderation',
    jsonb_build_object(
      'source_type', NEW.source_type,
      'moderation_status', NEW.moderation_status,
      'submitted_at', now()
    )
  FROM public.user_roles role_row
  WHERE role_row.role::text IN ('moderator', 'admin', 'super_admin');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_staff_track_moderation_submission_trigger ON public.tracks;
CREATE TRIGGER notify_staff_track_moderation_submission_trigger
AFTER INSERT OR UPDATE OF moderation_status ON public.tracks
FOR EACH ROW
EXECUTE FUNCTION public.notify_staff_track_moderation_submission();

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
  v_previous_bypass text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  SELECT *
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id
    AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Трек не найден';
  END IF;

  IF v_track.moderation_status = 'pending' THEN
    RETURN v_track;
  END IF;

  IF COALESCE(v_track.moderation_status, 'none') NOT IN ('none', 'rejected') THEN
    RAISE EXCEPTION 'Трек нельзя отправить на модерацию из текущего статуса';
  END IF;

  IF COALESCE(btrim(v_track.audio_url), '') = '' THEN
    RAISE EXCEPTION 'У трека отсутствует аудиофайл';
  END IF;

  v_title := COALESCE(NULLIF(btrim(p_title), ''), NULLIF(btrim(v_track.title), ''));
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'Укажите название трека';
  END IF;

  v_previous_bypass := current_setting('app.bypass_track_protection', true);
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  UPDATE public.tracks
  SET
    title = v_title,
    description = CASE
      WHEN p_description IS NULL THEN description
      ELSE NULLIF(btrim(p_description), '')
    END,
    status = 'pending',
    moderation_status = 'pending',
    moderation_rejection_reason = NULL,
    moderation_notes = NULL,
    moderation_reviewed_at = NULL,
    moderation_reviewed_by = NULL,
    updated_at = now()
  WHERE id = p_track_id
  RETURNING * INTO v_track;

  PERFORM set_config(
    'app.bypass_track_protection',
    COALESCE(v_previous_bypass, 'false'),
    true
  );

  RETURN v_track;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_track_for_moderation(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_track_for_moderation(uuid, text, text) TO authenticated;
