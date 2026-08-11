BEGIN;

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

  INSERT INTO public.notifications (
    user_id, type, title, message, actor_id, target_type, target_id, link, metadata
  )
  SELECT DISTINCT
    role_row.user_id,
    'new_track_moderation',
    'Новый трек на модерации',
    COALESCE(v_artist_name, 'Пользователь') || ' отправил трек «'
      || COALESCE(NULLIF(btrim(NEW.title), ''), 'Без названия') || '».',
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
  WHERE role_row.role::text IN ('moderator', 'admin', 'super_admin')
    AND public.has_permission(role_row.user_id, 'moderation');

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderate_track(
  p_track_id uuid,
  p_decision text,
  p_reason text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_expected_status text DEFAULT 'pending',
  p_override boolean DEFAULT false
)
RETURNS public.tracks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_track public.tracks%ROWTYPE;
  v_health_status text;
  v_issues text[] := ARRAY[]::text[];
  v_previous_bypass text;
BEGIN
  IF v_actor IS NULL OR NOT (public.is_admin(v_actor) OR public.has_permission(v_actor, 'moderation')) THEN
    RAISE EXCEPTION 'Требуются права модератора';
  END IF;
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Некорректное решение модерации';
  END IF;

  SELECT * INTO v_track
  FROM public.tracks
  WHERE id = p_track_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Трек не найден';
  END IF;
  IF v_track.moderation_status IS DISTINCT FROM p_expected_status THEN
    RAISE EXCEPTION 'Статус трека уже изменился. Обновите список и повторите действие';
  END IF;
  IF v_track.moderation_status <> 'pending' THEN
    RAISE EXCEPTION 'Решение модерации доступно только для трека в статусе pending';
  END IF;

  IF p_decision = 'rejected' AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Укажите причину отклонения';
  END IF;

  IF p_decision = 'approved' THEN
    SELECT analysis_status INTO v_health_status
    FROM public.track_health_reports
    WHERE track_id = p_track_id;

    IF v_track.copyright_check_status <> 'clean' THEN
      v_issues := array_append(v_issues, 'проверка авторских прав не завершена');
    END IF;
    IF v_track.plagiarism_check_status <> 'clean' THEN
      v_issues := array_append(v_issues, 'проверка совпадений не завершена');
    END IF;
    IF COALESCE(v_health_status, 'missing') <> 'completed' THEN
      v_issues := array_append(v_issues, 'технический анализ аудио не завершён');
    END IF;
    IF COALESCE(v_track.has_samples, false) AND NOT COALESCE(v_track.samples_licensed, false) THEN
      v_issues := array_append(v_issues, 'не подтверждена лицензия на сэмплы');
    END IF;
    IF cardinality(v_issues) > 0 AND NOT p_override THEN
      RAISE EXCEPTION 'Одобрение заблокировано: %', array_to_string(v_issues, '; ');
    END IF;
    IF cardinality(v_issues) > 0 AND COALESCE(btrim(p_notes), '') = '' THEN
      RAISE EXCEPTION 'Для ручного обхода проверок обязателен комментарий';
    END IF;
  END IF;

  v_previous_bypass := current_setting('app.bypass_track_protection', true);
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  IF p_decision = 'approved' THEN
    UPDATE public.tracks
    SET moderation_status = 'approved',
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_notes = NULLIF(btrim(p_notes), ''),
        moderation_rejection_reason = NULL,
        status = 'completed',
        is_public = true,
        updated_at = now()
    WHERE id = p_track_id
    RETURNING * INTO v_track;
  ELSE
    UPDATE public.tracks
    SET moderation_status = 'rejected',
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_notes = NULLIF(btrim(p_notes), ''),
        moderation_rejection_reason = btrim(p_reason),
        status = 'completed',
        is_public = false,
        updated_at = now()
    WHERE id = p_track_id
    RETURNING * INTO v_track;
  END IF;

  INSERT INTO public.moderation_events (
    track_id, track_user_id, actor_id, action, from_status, to_status, reason, notes, metadata
  )
  VALUES (
    v_track.id,
    v_track.user_id,
    v_actor,
    p_decision,
    'pending',
    p_decision,
    NULLIF(btrim(p_reason), ''),
    NULLIF(btrim(p_notes), ''),
    jsonb_build_object('override', p_override, 'issues', to_jsonb(v_issues))
  );

  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_track.user_id,
    CASE WHEN p_decision = 'approved' THEN 'track_approved' ELSE 'track_rejected' END,
    CASE WHEN p_decision = 'approved' THEN 'Трек одобрен!' ELSE 'Трек отклонён' END,
    CASE WHEN p_decision = 'approved'
      THEN format('Ваш трек "%s" прошёл модерацию и опубликован.', v_track.title)
      ELSE format('Ваш трек "%s" не прошёл модерацию. Причина: %s', v_track.title, btrim(p_reason))
    END,
    v_actor,
    'track',
    v_track.id
  );

  PERFORM set_config('app.bypass_track_protection', COALESCE(v_previous_bypass, 'false'), true);
  RETURN v_track;
END;
$$;

REVOKE ALL ON FUNCTION public.moderate_track(uuid, text, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.moderate_track(uuid, text, text, text, text, boolean)
  TO authenticated, service_role;

COMMIT;
