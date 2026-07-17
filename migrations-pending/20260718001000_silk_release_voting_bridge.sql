-- Connect the manual Silk release queue to the public track voting system.

CREATE OR REPLACE FUNCTION public.send_silk_release_to_voting(
  p_release_id uuid,
  p_duration_days integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_track public.tracks%ROWTYPE;
  v_audio public.silk_release_assets%ROWTYPE;
  v_master public.silk_release_assets%ROWTYPE;
  v_cover public.silk_release_assets%ROWTYPE;
  v_voting jsonb;
  v_audio_url text;
  v_master_url text;
  v_cover_url text;
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin(v_admin_id) THEN
    RAISE EXCEPTION 'Доступ запрещён';
  END IF;

  SELECT * INTO v_release
  FROM public.silk_releases
  WHERE id = p_release_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  IF v_release.status NOT IN ('submitted', 'voting') THEN
    RAISE EXCEPTION 'Голосование можно запустить только для проверяемого релиза';
  END IF;

  SELECT * INTO v_audio
  FROM public.silk_release_assets
  WHERE release_id = p_release_id
    AND asset_type = 'reference_mp3'
    AND validation_status = 'valid'
    AND coalesce(file_size, 0) > 0
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT * INTO v_master
  FROM public.silk_release_assets
  WHERE release_id = p_release_id
    AND asset_type = 'master_wav'
    AND validation_status = 'valid'
    AND coalesce(file_size, 0) > 0
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT * INTO v_cover
  FROM public.silk_release_assets
  WHERE release_id = p_release_id
    AND asset_type = 'cover_art'
    AND validation_status = 'valid'
    AND coalesce(file_size, 0) > 0
  ORDER BY updated_at DESC
  LIMIT 1;

  IF v_audio.id IS NULL AND v_master.id IS NULL THEN
    RAISE EXCEPTION 'Для голосования нужен MP3 или Master WAV';
  END IF;
  IF v_cover.id IS NULL THEN
    RAISE EXCEPTION 'Для голосования нужна обложка';
  END IF;

  v_audio_url := '/storage/v1/object/public/' || coalesce(v_audio.storage_bucket, v_master.storage_bucket)
    || '/' || coalesce(v_audio.storage_path, v_master.storage_path);
  v_master_url := CASE WHEN v_master.id IS NOT NULL THEN
    '/storage/v1/object/public/' || v_master.storage_bucket || '/' || v_master.storage_path
    ELSE NULL END;
  v_cover_url := '/storage/v1/object/public/' || v_cover.storage_bucket || '/' || v_cover.storage_path;

  IF v_release.source_track_id IS NULL THEN
    INSERT INTO public.tracks(
      user_id, title, description, audio_url, audio_reference_url, cover_url,
      wav_url, master_audio_url, performer_name, label_name,
      music_author, lyrics_author, source_type, status,
      moderation_status, distribution_status, is_public,
      is_release_candidate, is_in_my_releases
    ) VALUES (
      v_release.user_id,
      v_release.title,
      nullif(v_release.user_note, ''),
      v_audio_url,
      v_audio_url,
      v_cover_url,
      v_master_url,
      v_master_url,
      v_release.artist_name,
      coalesce(nullif(v_release.label_name, ''), 'Нота-Фея'),
      v_release.music_author,
      v_release.lyrics_author,
      'uploaded',
      'completed',
      'pending',
      NULL,
      false,
      true,
      true
    ) RETURNING * INTO v_track;

    UPDATE public.silk_releases
    SET source_track_id = v_track.id, updated_at = now()
    WHERE id = p_release_id
    RETURNING * INTO v_release;
  ELSE
    SELECT * INTO v_track
    FROM public.tracks
    WHERE id = v_release.source_track_id
    FOR UPDATE;

    IF NOT FOUND OR v_track.user_id <> v_release.user_id THEN
      RAISE EXCEPTION 'Связанный трек релиза не найден';
    END IF;

    UPDATE public.tracks
    SET title = v_release.title,
        description = nullif(v_release.user_note, ''),
        audio_url = v_audio_url,
        audio_reference_url = v_audio_url,
        cover_url = v_cover_url,
        wav_url = v_master_url,
        master_audio_url = v_master_url,
        performer_name = v_release.artist_name,
        label_name = coalesce(nullif(v_release.label_name, ''), 'Нота-Фея'),
        music_author = v_release.music_author,
        lyrics_author = v_release.lyrics_author,
        updated_at = now()
    WHERE id = v_track.id
    RETURNING * INTO v_track;
  END IF;

  IF v_track.moderation_status = 'voting'
     AND v_track.voting_result = 'pending'
     AND v_track.voting_ends_at > now()
  THEN
    SELECT jsonb_build_object(
      'success', true,
      'already_active', true,
      'track_id', v_track.id,
      'forum_topic_id', v_track.forum_topic_id,
      'voting_ends_at', v_track.voting_ends_at
    ) INTO v_voting;
  ELSE
    v_voting := public.send_track_to_voting(v_track.id, p_duration_days, 'public');
  END IF;

  IF v_release.status = 'submitted' THEN
    UPDATE public.silk_releases
    SET status = 'voting', reviewed_at = now(), updated_at = now()
    WHERE id = p_release_id;
  END IF;

  INSERT INTO public.silk_release_events(
    release_id, actor_id, event_type, from_status, to_status, payload
  ) VALUES (
    p_release_id,
    v_admin_id,
    'voting_started',
    v_release.status,
    'voting',
    jsonb_build_object(
      'track_id', v_track.id,
      'forum_topic_id', v_voting->'forum_topic_id',
      'duration_days', coalesce(p_duration_days, (SELECT value::integer FROM public.settings WHERE key = 'voting_duration_days'), 7)
    )
  );

  RETURN v_voting || jsonb_build_object('release_id', p_release_id, 'track_id', v_track.id);
END;
$$;

REVOKE ALL ON FUNCTION public.send_silk_release_to_voting(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_silk_release_to_voting(uuid, integer) TO authenticated;

-- A Silk release may enter voting only after a real active track voting was created.
CREATE OR REPLACE FUNCTION public.validate_silk_release_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;

  IF NEW.status = 'voting' AND NOT EXISTS (
    SELECT 1 FROM public.tracks track
    WHERE track.id = NEW.source_track_id
      AND track.user_id = NEW.user_id
      AND track.moderation_status = 'voting'
      AND track.voting_type = 'public'
      AND track.voting_result = 'pending'
      AND track.voting_ends_at > now()
  ) THEN
    RAISE EXCEPTION 'Сначала настройте и запустите публичное голосование';
  END IF;

  IF NEW.status = 'archived' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.silk_release_requests request_row
      WHERE request_row.release_id = OLD.id
        AND request_row.request_type = 'deletion'
        AND request_row.status = 'open'
    ) THEN
      RAISE EXCEPTION 'Архивация разрешена только по открытому запросу на удаление';
    END IF;
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status IN ('draft', 'ready', 'needs_changes', 'rejected') AND NEW.status = 'submitted')
    OR (OLD.status = 'submitted' AND NEW.status IN ('needs_changes', 'voting', 'approved', 'rejected'))
    OR (OLD.status = 'voting' AND NEW.status IN ('needs_changes', 'approved', 'rejected'))
    OR (OLD.status = 'approved' AND NEW.status IN ('needs_changes', 'sent_to_silk', 'rejected'))
    OR (OLD.status = 'sent_to_silk' AND NEW.status IN ('live', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Недопустимый переход статуса: % → %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$;

-- Keep the manual release queue synchronized when voting is resolved manually or automatically.
CREATE OR REPLACE FUNCTION public.sync_silk_release_voting_result()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_release record;
  v_status text;
  v_title text;
BEGIN
  IF OLD.moderation_status IS DISTINCT FROM 'voting'
     OR OLD.voting_result IS DISTINCT FROM 'pending'
     OR NEW.voting_result NOT IN (
       'approved', 'voting_approved', 'manual_override_approved',
       'rejected', 'manual_override_rejected'
     )
  THEN
    RETURN NEW;
  END IF;

  v_status := CASE
    WHEN NEW.voting_result IN ('approved', 'voting_approved', 'manual_override_approved') THEN 'approved'
    ELSE 'rejected'
  END;
  v_title := CASE v_status WHEN 'approved' THEN 'Релиз: Одобрен по итогам голосования'
                           ELSE 'Релиз: Отклонён по итогам голосования' END;

  FOR v_release IN
    UPDATE public.silk_releases
    SET status = v_status,
        reviewed_at = now(),
        admin_note = CASE v_status
          WHEN 'approved' THEN 'Одобрено по итогам голосования сообщества'
          ELSE 'Отклонено по итогам голосования сообщества'
        END,
        updated_at = now()
    WHERE source_track_id = NEW.id AND status = 'voting'
    RETURNING id, user_id, title
  LOOP
    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, auth.uid(), 'voting_resolved', 'voting', v_status,
      jsonb_build_object('track_id', NEW.id, 'voting_result', NEW.voting_result));

    INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id, link, metadata)
    VALUES (v_release.user_id, 'system', v_title,
      'Голосование по релизу «' || v_release.title || '» завершено',
      'silk_release', v_release.id, '/?tab=my-releases',
      jsonb_build_object('status', v_status, 'track_id', NEW.id));
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_silk_release_voting_result_trigger ON public.tracks;
CREATE TRIGGER sync_silk_release_voting_result_trigger
AFTER UPDATE OF moderation_status, voting_result ON public.tracks
FOR EACH ROW
EXECUTE FUNCTION public.sync_silk_release_voting_result();

-- Translate legacy and future release status notification titles.
CREATE OR REPLACE FUNCTION public.translate_silk_release_notification_title()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_status text;
BEGIN
  IF NEW.target_type = 'silk_release' AND NEW.title LIKE 'Релиз: %' THEN
    v_status := coalesce(NEW.metadata->>'status', substring(NEW.title from 8));
    NEW.title := 'Релиз: ' || CASE v_status
      WHEN 'draft' THEN 'Черновик'
      WHEN 'ready' THEN 'Готовится'
      WHEN 'submitted' THEN 'На проверке'
      WHEN 'needs_changes' THEN 'Нужны правки'
      WHEN 'voting' THEN 'Выставлен на голосование'
      WHEN 'approved' THEN 'Одобрен'
      WHEN 'sent_to_silk' THEN 'Отправлен на площадки'
      WHEN 'live' THEN 'Опубликован'
      WHEN 'rejected' THEN 'Отклонён'
      WHEN 'archived' THEN 'Архив'
      ELSE v_status END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS translate_silk_release_notification_title_trigger ON public.notifications;
CREATE TRIGGER translate_silk_release_notification_title_trigger
BEFORE INSERT OR UPDATE OF title, metadata ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.translate_silk_release_notification_title();

UPDATE public.notifications
SET title = title
WHERE target_type = 'silk_release' AND title LIKE 'Релиз: %';

UPDATE public.forum_categories
SET slug = 'voting', updated_at = now()
WHERE id = (SELECT value::uuid FROM public.settings WHERE key = 'forum_voting_category_id')
  AND NOT EXISTS (SELECT 1 FROM public.forum_categories WHERE slug = 'voting');
