-- Shared by the administrative deletion and the owner command after approval.
CREATE FUNCTION public.purge_silk_release(
  v_release public.silk_releases, v_track_id uuid
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp
AS $$
BEGIN
  IF v_track_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.silk_releases other
    WHERE other.source_track_id = v_track_id AND other.id <> v_release.id
      AND NOT (v_release.source_kind = 'generated' AND other.source_kind = 'generated'
               AND other.user_id = v_release.user_id AND other.status = 'archived')
  ) THEN
    RAISE EXCEPTION 'Связанный трек используется в другой заявке на релиз';
  END IF;

  DELETE FROM public.silk_releases
  WHERE id = v_release.id
     OR (source_track_id = v_track_id AND source_kind = 'generated'
         AND user_id = v_release.user_id AND status = 'archived');
  IF v_track_id IS NOT NULL THEN
    DELETE FROM public.distribution_requests WHERE track_id = v_track_id;
    DELETE FROM public.feed_posts WHERE track_id = v_track_id AND is_release_announcement;
    UPDATE public.tracks
    SET is_release_candidate = false, distribution_status = 'none'
    WHERE id = v_track_id;
    DELETE FROM public.tracks WHERE id = v_track_id;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_silk_release(public.silk_releases, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_manage_silk_release(
  p_release_id uuid, p_action text, p_reason text
)
RETURNS public.silk_releases
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_track_id uuid;
  v_from text;
  v_to text;
  v_label text;
  v_action text := CASE p_action WHEN 'delete' THEN 'remove_from_queue' ELSE p_action END;
  v_reason text := nullif(btrim(p_reason), '');
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin(v_actor) THEN
    RAISE EXCEPTION 'Доступ запрещён';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину для уведомления пользователя'; END IF;
  IF v_action IS NULL OR v_action NOT IN ('suspend', 'withdraw', 'remove_from_queue', 'delete_from_site', 'resume') THEN
    RAISE EXCEPTION 'Неизвестное действие';
  END IF;

  IF v_action IN ('remove_from_queue', 'delete_from_site') THEN
    -- Match the lock order of submit_generated_track_release and track deletion.
    SELECT track.id INTO v_track_id
    FROM public.tracks track
    JOIN public.silk_releases release
      ON release.source_track_id = track.id AND release.user_id = track.user_id
    WHERE release.id = p_release_id
    FOR UPDATE OF track;
  END IF;
  SELECT * INTO v_release FROM public.silk_releases WHERE id = p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  IF v_action IN ('remove_from_queue', 'delete_from_site')
     AND v_release.source_track_id IS DISTINCT FROM v_track_id THEN
    RAISE EXCEPTION 'Связанный трек изменился. Обновите карточку и повторите действие';
  END IF;

  v_from := v_release.status;
  IF v_action = 'delete_from_site' THEN
    PERFORM public.purge_silk_release(v_release, v_track_id);
    v_label := 'удалён с сайта';
  ELSE
    v_to := CASE v_action
      WHEN 'suspend' THEN 'suspended'
      WHEN 'withdraw' THEN 'withdrawn'
      WHEN 'remove_from_queue' THEN 'draft'
      ELSE v_release.metadata->>'admin_previous_status'
    END;
    v_label := CASE v_action
      WHEN 'suspend' THEN 'приостановлен'
      WHEN 'withdraw' THEN 'отозван'
      WHEN 'remove_from_queue' THEN 'снят с очереди и возвращён в черновики'
      ELSE 'возобновлён'
    END;
    IF v_action = 'resume' AND (v_from <> 'suspended' OR v_to IS NULL OR
       v_to NOT IN ('draft','ready','submitted','needs_changes','approved','sending','sent_to_silk','live','rejected','archived','withdrawn')) THEN
      RAISE EXCEPTION 'Этот релиз нельзя возобновить';
    END IF;
    IF v_action = 'remove_from_queue' AND v_from IN ('draft', 'ready') THEN
      RAISE EXCEPTION 'Релиз уже вне очереди';
    END IF;
    IF v_to = v_from THEN RAISE EXCEPTION 'Действие уже выполнено'; END IF;

    IF v_action = 'remove_from_queue' THEN
      IF v_release.source_kind = 'generated' AND v_track_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.silk_releases other
        WHERE other.source_track_id = v_track_id AND other.source_kind = 'generated'
          AND other.id <> p_release_id AND other.status <> 'archived'
      ) THEN
        RAISE EXCEPTION 'У этого трека уже есть активная карточка релиза';
      END IF;

      UPDATE public.silk_releases
      SET status = v_to, admin_note = v_reason, submitted_at = NULL, reviewed_at = NULL,
          sending_started_at = NULL, sent_to_silk_at = NULL, live_at = NULL,
          isrc_code = NULL, upc_code = NULL,
          metadata = (metadata - 'admin_previous_status') || jsonb_build_object(
            'admin_action', v_action, 'admin_action_at', now())
      WHERE id = p_release_id RETURNING * INTO v_release;
      IF v_release.source_kind = 'generated' AND v_track_id IS NOT NULL THEN
        UPDATE public.tracks SET is_sent_to_release = false, is_release_candidate = false
        WHERE id = v_track_id;
      END IF;
    ELSE
      UPDATE public.silk_releases
      SET status = v_to, admin_note = v_reason,
          metadata = metadata || jsonb_build_object(
            'admin_previous_status', v_from, 'admin_action', v_action, 'admin_action_at', now())
      WHERE id = p_release_id RETURNING * INTO v_release;
    END IF;

    IF v_action IN ('remove_from_queue', 'withdraw') THEN
      UPDATE public.silk_release_requests
      SET status = 'declined', admin_note = v_reason, resolved_at = now()
      WHERE release_id = p_release_id AND (
        status = 'open'
        OR (v_action = 'remove_from_queue' AND v_from = 'archived'
            AND request_type = 'deletion' AND status = 'approved')
      );
    END IF;
    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (p_release_id, v_actor, 'admin_action', v_from, v_to,
            jsonb_build_object('action', v_action, 'reason', v_reason));
  END IF;

  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  VALUES (v_release.user_id, 'system', 'Релиз ' || v_label,
    'Релиз «' || v_release.title || '» ' || v_label || '. Причина: ' || v_reason,
    v_actor,
    CASE WHEN v_to IS NOT NULL THEN 'silk_release' END,
    CASE WHEN v_to IS NOT NULL THEN p_release_id END,
    '/?tab=my-releases', jsonb_build_object('status', v_to, 'action', v_action, 'reason', v_reason));
  RETURN v_release;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_approved_silk_release(p_release_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_track_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  SELECT track.id INTO v_track_id
  FROM public.tracks track
  JOIN public.silk_releases release
    ON release.source_track_id = track.id AND release.user_id = track.user_id
  WHERE release.id = p_release_id AND release.user_id = v_user_id
    AND release.source_kind = 'generated'
  FOR UPDATE OF track;

  SELECT * INTO v_release FROM public.silk_releases
  WHERE id = p_release_id AND user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  IF v_release.status <> 'archived' THEN
    RAISE EXCEPTION 'Релиз должен быть архивирован после одобрения запроса на удаление';
  END IF;
  IF v_release.source_kind = 'generated'
     AND v_release.source_track_id IS DISTINCT FROM v_track_id THEN
    RAISE EXCEPTION 'Связанный трек изменился. Обновите карточку и повторите действие';
  END IF;

  PERFORM 1 FROM public.silk_release_requests
  WHERE release_id = p_release_id AND user_id = v_user_id
    AND request_type = 'deletion' AND status = 'approved'
  ORDER BY resolved_at DESC NULLS LAST, created_at DESC
  LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Нет одобренного запроса на удаление'; END IF;

  PERFORM public.purge_silk_release(v_release, v_track_id);
  RETURN p_release_id;
END;
$$;
