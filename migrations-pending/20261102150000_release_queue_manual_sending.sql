-- Единая очередь релизов музыкального лейбла АИМУЗА.
--
-- 1) Голосование по релизам полностью убирается: статус voting снимается,
--    bridge-функции и триггеры голосования удаляются.
-- 2) Новый статус sending («Отправляется»): админ начал ручную отправку
--    на площадки. Статус живёт в БД, страницу можно закрыть.
-- 3) Переход в sent_to_silk («Отправлен») возможен только при заполненном
--    ISRC или UPC — ввод кода и есть факт завершения отправки
--    (функция admin_set_silk_release_codes).
-- 4) Колонка source_kind: generated | uploaded | external. Сгенерированные
--    на сайте релизы заходят в общую очередь кнопкой «Отправлен» из
--    «Моих релизов» через submit_generated_track_release.

-- ============================================================================
-- 1. Демонтаж голосовательного моста релизов
-- ============================================================================

UPDATE public.silk_releases
SET status = 'approved',
    reviewed_at = COALESCE(reviewed_at, now()),
    admin_note = COALESCE(
      NULLIF(btrim(admin_note), ''),
      'Одобрено: голосование по релизам отключено'
    ),
    updated_at = now()
WHERE status = 'voting';

DROP TRIGGER IF EXISTS sync_silk_release_voting_result_trigger ON public.tracks;
DROP TRIGGER IF EXISTS normalize_silk_voting_bridge_track_trigger ON public.tracks;
DROP TRIGGER IF EXISTS route_silk_voting_result_notification_trigger ON public.notifications;

DROP FUNCTION IF EXISTS public.send_silk_release_to_voting(uuid, integer);
DROP FUNCTION IF EXISTS public.sync_silk_release_voting_result();
DROP FUNCTION IF EXISTS public.route_silk_voting_result_notification();
DROP FUNCTION IF EXISTS public.normalize_silk_voting_bridge_track();

-- ============================================================================
-- 2. Схема: новые статусы и источник релиза
-- ============================================================================

ALTER TABLE public.silk_releases DROP CONSTRAINT IF EXISTS silk_releases_status_check;

ALTER TABLE public.silk_releases
  ADD CONSTRAINT silk_releases_status_check CHECK (
    status IN (
      'draft',
      'ready',
      'submitted',
      'needs_changes',
      'approved',
      'sending',
      'sent_to_silk',
      'live',
      'rejected',
      'archived'
    )
  );

ALTER TABLE public.silk_releases
  ADD COLUMN IF NOT EXISTS source_kind text NOT NULL DEFAULT 'external';

ALTER TABLE public.silk_releases DROP CONSTRAINT IF EXISTS silk_releases_source_kind_check;
ALTER TABLE public.silk_releases
  ADD CONSTRAINT silk_releases_source_kind_check CHECK (
    source_kind IN ('generated', 'uploaded', 'external')
  );

ALTER TABLE public.silk_releases
  ADD COLUMN IF NOT EXISTS sending_started_at timestamptz;

-- Один сгенерированный релиз на трек (архивные не считаем).
CREATE UNIQUE INDEX IF NOT EXISTS idx_silk_releases_generated_track
  ON public.silk_releases(source_track_id)
  WHERE source_kind = 'generated' AND status <> 'archived';

-- ============================================================================
-- 3. Машина состояний
-- ============================================================================

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
    OR (OLD.status = 'approved' AND NEW.status IN ('needs_changes', 'sending', 'rejected'))
    OR (OLD.status = 'sending' AND NEW.status IN ('needs_changes', 'rejected', 'sent_to_silk'))
    OR (OLD.status = 'sent_to_silk' AND NEW.status IN ('live', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Недопустимый переход статуса: % → %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_silk_release_status_transition_trigger ON public.silk_releases;
CREATE TRIGGER validate_silk_release_status_transition_trigger
BEFORE UPDATE OF status ON public.silk_releases
FOR EACH ROW
EXECUTE FUNCTION public.validate_silk_release_status_transition();

CREATE OR REPLACE FUNCTION public.validate_silk_release_request_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_release public.silk_releases%ROWTYPE;
BEGIN
  SELECT * INTO v_release
  FROM public.silk_releases
  WHERE id = NEW.release_id;

  IF NOT FOUND OR v_release.user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Релиз не найден или не принадлежит пользователю';
  END IF;

  IF NEW.request_type = 'editing'
     AND v_release.status NOT IN ('submitted', 'approved', 'sending') THEN
    RAISE EXCEPTION 'Редактирование нельзя запросить из текущего статуса';
  END IF;

  IF NEW.request_type = 'deletion' AND v_release.status = 'archived' THEN
    RAISE EXCEPTION 'Релиз уже находится в архиве';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_silk_release_request_state_trigger ON public.silk_release_requests;
CREATE TRIGGER validate_silk_release_request_state_trigger
BEFORE INSERT ON public.silk_release_requests
FOR EACH ROW
EXECUTE FUNCTION public.validate_silk_release_request_state();

-- ============================================================================
-- 4. Админские переходы: без sent_to_silk (только через ввод кодов)
--    и без голосования
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_transition_silk_release(
  p_release_id uuid,
  p_status text,
  p_admin_note text DEFAULT NULL,
  p_request_status text DEFAULT NULL
)
RETURNS public.silk_releases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_from_status text;
  v_now timestamptz := now();
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin(v_admin_id) THEN RAISE EXCEPTION 'Доступ запрещён'; END IF;
  IF p_status NOT IN ('needs_changes', 'approved', 'sending', 'live', 'rejected', 'archived') THEN
    RAISE EXCEPTION 'Неизвестный статус релиза';
  END IF;
  IF p_status IN ('needs_changes', 'rejected') AND btrim(coalesce(p_admin_note, '')) = '' THEN
    RAISE EXCEPTION 'Укажите причину решения';
  END IF;

  SELECT * INTO v_release FROM public.silk_releases WHERE id = p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  v_from_status := v_release.status;

  IF p_status <> 'archived' AND NOT (
    (v_from_status = 'submitted' AND p_status IN ('needs_changes', 'approved', 'rejected'))
    OR (v_from_status = 'approved' AND p_status IN ('needs_changes', 'sending', 'rejected'))
    OR (v_from_status = 'sending' AND p_status IN ('needs_changes', 'rejected'))
    OR (v_from_status = 'sent_to_silk' AND p_status IN ('live', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Недопустимый переход статуса: % → %', v_from_status, p_status;
  END IF;

  -- Для сгенерированных релизов комплект — это готовый ZIP релиз-пакета;
  -- для загруженных и внешних — WAV, MP3, обложка и архив.
  IF p_status IN ('approved', 'sending') THEN
    IF v_release.source_kind = 'generated' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.silk_release_assets asset
        WHERE asset.release_id = p_release_id
          AND asset.asset_type = 'package_zip'
          AND asset.validation_status = 'valid'
          AND (btrim(coalesce(asset.storage_path, '')) <> ''
               OR btrim(coalesce(asset.public_url, '')) <> '')
      ) THEN RAISE EXCEPTION 'ZIP релиз-пакета недоступен'; END IF;
    ELSE
      IF EXISTS (
        SELECT 1 FROM unnest(ARRAY['master_wav', 'reference_mp3', 'cover_art', 'package_zip']) required_type
        WHERE NOT EXISTS (
          SELECT 1 FROM public.silk_release_assets asset
          WHERE asset.release_id = p_release_id AND asset.asset_type = required_type
            AND asset.validation_status = 'valid' AND coalesce(asset.file_size, 0) > 0
        )
      ) THEN RAISE EXCEPTION 'Комплект релиза неполный'; END IF;
    END IF;
  END IF;

  UPDATE public.silk_releases SET
    status = p_status,
    admin_note = nullif(btrim(coalesce(p_admin_note, '')), ''),
    reviewed_at = CASE WHEN p_status IN ('needs_changes', 'approved', 'rejected') THEN v_now ELSE reviewed_at END,
    sending_started_at = CASE WHEN p_status = 'sending' THEN v_now ELSE sending_started_at END,
    live_at = CASE WHEN p_status = 'live' THEN v_now ELSE live_at END,
    updated_at = v_now
  WHERE id = p_release_id RETURNING * INTO v_release;

  IF p_request_status IS NOT NULL THEN
    IF p_request_status NOT IN ('approved', 'declined') THEN RAISE EXCEPTION 'Неизвестный статус запроса'; END IF;
    UPDATE public.silk_release_requests SET status = p_request_status,
      admin_note = nullif(btrim(coalesce(p_admin_note, '')), ''), resolved_at = v_now
    WHERE id = (SELECT id FROM public.silk_release_requests
      WHERE release_id = p_release_id AND status = 'open' ORDER BY created_at DESC LIMIT 1);
  END IF;

  INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
  VALUES (p_release_id, v_admin_id, 'status_changed', v_from_status, p_status,
    jsonb_build_object('admin_note', p_admin_note));
  INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id, link, metadata)
  VALUES (v_release.user_id, 'system', 'Релиз: ' || p_status,
    coalesce(nullif(btrim(coalesce(p_admin_note, '')), ''), 'Статус «' || v_release.title || '» изменён'),
    'silk_release', p_release_id, '/?tab=my-releases', jsonb_build_object('status', p_status));

  RETURN v_release;
END;
$$;

-- ============================================================================
-- 5. Ввод ISRC/UPC: завершение ручной отправки
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_set_silk_release_codes(
  p_release_id uuid,
  p_isrc text DEFAULT NULL,
  p_upc text DEFAULT NULL
)
RETURNS public.silk_releases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_from_status text;
  v_isrc text := upper(regexp_replace(coalesce(p_isrc, ''), '[^A-Za-z0-9]', '', 'g'));
  v_upc text := regexp_replace(coalesce(p_upc, ''), '[^0-9]', '', 'g');
  v_now timestamptz := now();
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin(v_admin_id) THEN RAISE EXCEPTION 'Доступ запрещён'; END IF;

  IF btrim(v_isrc) = '' AND btrim(v_upc) = '' THEN
    RAISE EXCEPTION 'Введите ISRC или UPC — без кода релиз не считается отправленным';
  END IF;
  IF btrim(v_isrc) <> '' AND v_isrc !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' THEN
    RAISE EXCEPTION 'ISRC состоит из 12 знаков: 2 буквы страны, 3 знака регистратора, 7 цифр (например RU0123456789)';
  END IF;
  IF btrim(v_upc) <> '' AND v_upc !~ '^[0-9]{12,13}$' THEN
    RAISE EXCEPTION 'UPC/EAN состоит из 12 или 13 цифр';
  END IF;

  SELECT * INTO v_release FROM public.silk_releases WHERE id = p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;

  IF v_release.status NOT IN ('approved', 'sending') THEN
    RAISE EXCEPTION 'Коды вводятся после одобрения, на этапе отправки';
  END IF;

  v_from_status := v_release.status;

  UPDATE public.silk_releases SET
    isrc_code = CASE WHEN btrim(v_isrc) = '' THEN isrc_code ELSE v_isrc END,
    upc_code = CASE WHEN btrim(v_upc) = '' THEN upc_code ELSE v_upc END,
    status = 'sent_to_silk',
    sent_to_silk_at = v_now,
    updated_at = v_now
  WHERE id = p_release_id
  RETURNING * INTO v_release;

  INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
  VALUES (p_release_id, v_admin_id, 'codes_set', v_from_status, 'sent_to_silk',
    jsonb_build_object('isrc', v_release.isrc_code, 'upc', v_release.upc_code));

  INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id, link, metadata)
  VALUES (v_release.user_id, 'system', 'Релиз: sent_to_silk',
    'Релиз «' || v_release.title || '» отправлен на площадки'
    || CASE WHEN btrim(coalesce(v_release.isrc_code, '')) <> ''
       THEN '. ISRC: ' || v_release.isrc_code ELSE '' END
    || CASE WHEN btrim(coalesce(v_release.upc_code, '')) <> ''
       THEN '. UPC: ' || v_release.upc_code ELSE '' END,
    'silk_release', p_release_id, '/?tab=my-releases',
    jsonb_build_object('status', 'sent_to_silk'));

  RETURN v_release;
END;
$$;

-- ============================================================================
-- 6. Кнопка «Отправлен» в «Моих релизах»: вход сгенерированного
--    релиз-пакета в общую очередь лейбла
-- ============================================================================

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
    IF v_release.status <> 'rejected' THEN
      RAISE EXCEPTION 'Релиз уже в очереди лейбла';
    END IF;
    -- Повторная отправка после отклонения.
    UPDATE public.silk_releases SET
      status = 'submitted',
      submitted_at = v_now,
      admin_note = NULL,
      updated_at = v_now
    WHERE id = v_release.id
    RETURNING * INTO v_release;

    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, v_user_id, 'submitted', 'rejected', 'submitted', '{}'::jsonb);
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
      storage_path = EXCLUDED.storage_path,
      public_url = EXCLUDED.public_url,
      validation_status = 'valid',
      updated_at = now();

    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, payload)
    VALUES (v_release.id, v_user_id, 'created',
      jsonb_build_object('source_kind', 'generated', 'track_id', p_track_id));
    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, v_user_id, 'submitted', 'draft', 'submitted', '{}'::jsonb);
  END IF;

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

GRANT EXECUTE ON FUNCTION public.admin_transition_silk_release(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_silk_release_codes(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_generated_track_release(uuid) TO authenticated;

-- ============================================================================
-- 7. Перевод статусов в уведомлениях: без голосования, с «Отправляется»
-- ============================================================================

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
      WHEN 'approved' THEN 'Одобрен'
      WHEN 'sending' THEN 'Отправляется'
      WHEN 'sent_to_silk' THEN 'Отправлен на площадки'
      WHEN 'live' THEN 'Опубликован'
      WHEN 'rejected' THEN 'Отклонён'
      WHEN 'archived' THEN 'Архив'
      ELSE v_status END;
  END IF;
  RETURN NEW;
END;
$$;
