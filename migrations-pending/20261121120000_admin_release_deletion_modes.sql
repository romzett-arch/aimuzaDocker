-- Commit release media cleanup with the deletion and let the worker protect shared files.
CREATE FUNCTION public.media_capture_deleted_silk_release()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.media_cleanup_jobs(track_id, payload)
  SELECT OLD.source_track_id, jsonb_agg(jsonb_build_object(
    'storage_bucket', asset.storage_bucket,
    'storage_path', nullif(asset.storage_path, ''),
    'public_url', asset.public_url
  ))
  FROM public.silk_release_assets asset
  WHERE asset.release_id = OLD.id
    AND (nullif(asset.storage_path, '') IS NOT NULL OR asset.public_url IS NOT NULL)
  HAVING count(*) > 0;

  DELETE FROM public.notifications
  WHERE target_type = 'silk_release' AND target_id = OLD.id;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.media_capture_deleted_silk_release() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER media_capture_deleted_silk_release
BEFORE DELETE ON public.silk_releases
FOR EACH ROW EXECUTE FUNCTION public.media_capture_deleted_silk_release();

CREATE OR REPLACE FUNCTION public.media_capture_deleted_track()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  files jsonb;
BEGIN
  IF OLD.is_release_candidate IS TRUE
     OR coalesce(OLD.distribution_status, 'none') NOT IN ('none', 'rejected')
     OR EXISTS (
       SELECT 1 FROM public.silk_releases release
       WHERE release.source_track_id = OLD.id
         AND NOT (release.source_kind = 'generated' AND release.status = 'draft'
                  AND release.user_id = OLD.user_id)
     ) THEN
    RAISE EXCEPTION 'Сначала отмените дистрибуцию / связь с релизом и снимите метку «В релиз»';
  END IF;

  DELETE FROM public.silk_releases
  WHERE source_track_id = OLD.id AND user_id = OLD.user_id
    AND source_kind = 'generated' AND status = 'draft';

  SELECT jsonb_build_object(
    'track', to_jsonb(OLD),
    'addons', coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM public.track_addons a WHERE track_id = OLD.id), '[]'),
    'packages', coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM public.release_packages p WHERE track_id = OLD.id), '[]'),
    'jobs', coalesce((SELECT jsonb_agg(to_jsonb(j)) FROM public.audio_master_jobs j WHERE track_id = OLD.id), '[]')
  ) INTO files;
  INSERT INTO public.media_cleanup_jobs(track_id, payload) VALUES (OLD.id, files);
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_silk_release_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'draft' AND NEW.submitted_at IS NULL
     AND NEW.metadata->>'admin_action' = 'remove_from_queue'
     AND public.is_admin(auth.uid()) THEN
    RETURN NEW;
  END IF;

  IF NEW.status IN ('suspended', 'withdrawn')
     OR (NEW.status = 'archived' AND public.is_admin(auth.uid()))
     OR (OLD.status = 'suspended' AND NEW.status = OLD.metadata->>'admin_previous_status') THEN
    IF NOT coalesce(public.is_admin(auth.uid()), false) THEN
      RAISE EXCEPTION 'Доступ запрещён';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = 'archived' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.silk_release_requests request_row
      WHERE request_row.release_id = OLD.id
        AND request_row.request_type = 'deletion'
        AND request_row.status = 'open'
    ) THEN
      RAISE EXCEPTION 'Архивация разрешена только по открытому запросу на удаление';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'sent_to_silk'
     AND btrim(coalesce(NEW.isrc_code, '')) = ''
     AND btrim(coalesce(NEW.upc_code, '')) = '' THEN
    RAISE EXCEPTION 'Отправленным релиз становится только после ввода ISRC или UPC';
  END IF;

  IF NOT (
    (OLD.status IN ('draft', 'ready', 'needs_changes', 'rejected') AND NEW.status = 'submitted')
    OR (OLD.status = 'submitted' AND NEW.status IN ('needs_changes', 'approved', 'rejected'))
    OR (OLD.status = 'approved' AND NEW.status IN ('needs_changes', 'sending', 'rejected', 'sent_to_silk'))
    OR (OLD.status = 'sending' AND NEW.status IN ('needs_changes', 'rejected', 'sent_to_silk'))
    OR (OLD.status = 'sent_to_silk' AND NEW.status IN ('live', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Недопустимый переход статуса: % → %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$;

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
    IF v_track_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.silk_releases other
      WHERE other.source_track_id = v_track_id AND other.id <> p_release_id
        AND NOT (v_release.source_kind = 'generated' AND other.source_kind = 'generated'
                 AND other.user_id = v_release.user_id AND other.status = 'archived')
    ) THEN
      RAISE EXCEPTION 'Связанный трек используется в другой заявке на релиз';
    END IF;

    DELETE FROM public.silk_releases
    WHERE id = p_release_id
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
    IF v_action = 'remove_from_queue' AND v_from IN ('draft', 'ready', 'archived') THEN
      RAISE EXCEPTION 'Релиз уже вне очереди';
    END IF;
    IF v_to = v_from THEN RAISE EXCEPTION 'Действие уже выполнено'; END IF;

    IF v_action = 'remove_from_queue' THEN
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
      WHERE release_id = p_release_id AND status = 'open';
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

-- The legacy queue removal wrote archived; restore only those administrative removals.
ALTER TABLE public.silk_releases DISABLE TRIGGER validate_silk_release_status_transition_trigger;

DELETE FROM public.silk_releases old_release
WHERE old_release.status = 'archived' AND old_release.source_kind = 'generated'
  AND old_release.metadata->>'admin_action' = 'delete'
  AND EXISTS (
    SELECT 1 FROM public.silk_releases latest
    WHERE latest.source_track_id = old_release.source_track_id
      AND latest.source_kind = 'generated' AND latest.id <> old_release.id
      AND (latest.status <> 'archived'
           OR (latest.metadata->>'admin_action' = 'delete'
               AND (latest.updated_at, latest.id) > (old_release.updated_at, old_release.id)))
  );

WITH restored AS (
  UPDATE public.silk_releases
  SET status = 'draft', submitted_at = NULL, reviewed_at = NULL, sending_started_at = NULL,
      sent_to_silk_at = NULL, live_at = NULL, isrc_code = NULL, upc_code = NULL,
      metadata = (metadata - 'admin_previous_status') || jsonb_build_object('admin_action', 'remove_from_queue')
  WHERE status = 'archived' AND metadata->>'admin_action' = 'delete'
  RETURNING source_track_id, source_kind, user_id
)
UPDATE public.tracks track SET is_sent_to_release = false, is_release_candidate = false
FROM restored
WHERE restored.source_kind = 'generated' AND track.id = restored.source_track_id
  AND track.user_id = restored.user_id;

ALTER TABLE public.silk_releases ENABLE TRIGGER validate_silk_release_status_transition_trigger;

CREATE OR REPLACE FUNCTION public.submit_generated_track_release(p_track_id uuid)
RETURNS public.silk_releases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_track public.tracks%ROWTYPE;
  v_package public.release_packages%ROWTYPE;
  v_release public.silk_releases%ROWTYPE;
  v_storage_path text;
  v_from_status text;
  v_now timestamptz := now();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  SELECT * INTO v_track FROM public.tracks
  WHERE id = p_track_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден'; END IF;
  IF NOT coalesce(v_track.is_in_my_releases, false) THEN
    RAISE EXCEPTION 'Сначала перенесите трек в «Мои релизы»';
  END IF;

  SELECT * INTO v_package FROM public.release_packages WHERE track_id = p_track_id;
  IF NOT FOUND OR v_package.status <> 'completed' OR btrim(coalesce(v_package.zip_url, '')) = '' THEN
    RAISE EXCEPTION 'Сначала соберите или загрузите ZIP релиз-пакета для этого трека';
  END IF;

  -- Путь в бакете tracks из публичной ссылки на архив.
  v_storage_path := CASE
    WHEN position('/object/public/tracks/' in v_package.zip_url) > 0
      THEN substring(v_package.zip_url from position('/object/public/tracks/' in v_package.zip_url) + length('/object/public/tracks/'))
    ELSE ''
  END;

  SELECT * INTO v_release FROM public.silk_releases
  WHERE source_track_id = p_track_id AND source_kind = 'generated' AND status <> 'archived'
  FOR UPDATE;

  IF FOUND THEN
    IF v_release.status NOT IN ('draft', 'rejected') THEN
      RAISE EXCEPTION 'Релиз уже в очереди лейбла';
    END IF;
    v_from_status := v_release.status;
    UPDATE public.silk_releases SET
      status = 'submitted',
      submitted_at = v_now,
      admin_note = NULL,
      updated_at = v_now
    WHERE id = v_release.id
    RETURNING * INTO v_release;

    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, v_user_id, 'submitted', v_from_status, 'submitted', '{}'::jsonb);
  ELSE
    INSERT INTO public.silk_releases(
      user_id, source_track_id, source_kind, status,
      title, artist_name, label_name, genre,
      music_author, lyrics_author,
      metadata, submitted_at
    ) VALUES (
      v_user_id, p_track_id, 'generated', 'submitted',
      coalesce(nullif(btrim(v_package.requested_title), ''), v_track.title, 'Без названия'),
      coalesce(nullif(btrim(coalesce(v_package.requested_performer_name, '')), ''), nullif(btrim(coalesce(v_track.performer_name, '')), ''), ''),
      'Музыкальный лейбл АИМУЗА',
      nullif(btrim(v_package.requested_genre), ''),
      coalesce(nullif(btrim(coalesce(v_package.requested_author_name, '')), ''), nullif(btrim(coalesce(v_track.performer_name, '')), ''), ''),
      coalesce(nullif(btrim(coalesce(v_package.requested_author_name, '')), ''), ''),
      jsonb_build_object(
        'legal_confirmations', jsonb_build_object(
          'not_cover_or_third_party_track', true,
          'owns_lyrics_rights', true,
          'owns_or_generated_music_rights', true,
          'no_profanity_or_prohibited_content', true
        ),
        'generated_release', true,
        'release_package_requested_has_lyrics', v_package.requested_has_lyrics,
        'release_package_requested_include_deposit', v_package.requested_include_deposit
      ),
      v_now
    )
    RETURNING * INTO v_release;

    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, payload)
    VALUES (v_release.id, v_user_id, 'created',
      jsonb_build_object('source_kind', 'generated', 'track_id', p_track_id));
    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, v_user_id, 'submitted', 'draft', 'submitted', '{}'::jsonb);
  END IF;

  INSERT INTO public.silk_release_assets(
    release_id, user_id, asset_type, file_name,
    storage_bucket, storage_path, public_url,
    content_type, file_size, validation_status
  ) VALUES (
    v_release.id, v_user_id, 'package_zip',
    coalesce(v_release.title, 'release') || '-package.zip',
    'tracks', v_storage_path,
    CASE WHEN btrim(v_storage_path) = '' THEN v_package.zip_url ELSE NULL END,
    'application/zip', NULL, 'valid'
  )
  ON CONFLICT (release_id, asset_type) DO UPDATE SET
    file_name = EXCLUDED.file_name,
    storage_path = EXCLUDED.storage_path,
    public_url = EXCLUDED.public_url,
    validation_status = 'valid',
    updated_at = now();

  INSERT INTO public.silk_release_assets(
    release_id, user_id, asset_type, file_name, storage_bucket, storage_path,
    public_url, content_type, file_size, validation_status
  )
  SELECT r.id, r.user_id, audio.asset_type,
    coalesce(nullif(btrim(r.title), ''), 'release') || audio.extension,
    'tracks', '', audio.url, audio.mime_type, NULL, 'valid'
  FROM public.silk_releases r
  JOIN public.release_packages p ON p.track_id=r.source_track_id AND p.user_id=r.user_id
  CROSS JOIN LATERAL (VALUES
    ('reference_mp3', p.mp3_url, 'audio/mpeg', '.mp3'),
    ('master_wav', p.wav_url, 'audio/wav', '.wav')
  ) AS audio(asset_type, url, mime_type, extension)
  WHERE r.id=v_release.id AND r.source_kind='generated' AND r.status<>'archived'
    AND p.status='completed' AND btrim(coalesce(audio.url,''))<>''
  ON CONFLICT (release_id, asset_type) DO UPDATE SET
    file_name=EXCLUDED.file_name, storage_bucket=EXCLUDED.storage_bucket,
    storage_path=EXCLUDED.storage_path, public_url=EXCLUDED.public_url,
    content_type=EXCLUDED.content_type, validation_status='valid', updated_at=now();

  UPDATE public.tracks SET is_sent_to_release = true WHERE id = p_track_id;

  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  SELECT DISTINCT role_row.user_id, 'system', 'Новый релиз для лейбла',
    coalesce(v_release.artist_name, 'Исполнитель') || ' отправил трек «' || v_release.title || '» в релиз.',
    v_user_id, 'silk_release', v_release.id, '/admin/distribution', '{"section":"distribution"}'::jsonb
  FROM public.user_roles role_row
  WHERE role_row.role::text IN ('admin', 'super_admin');

  RETURN v_release;
END;
$$;
