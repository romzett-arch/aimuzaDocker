-- Attach existing package audio without requiring users to upload it again.
-- Existing submitted packages are repaired by the same upsert used on submission.
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
WHERE r.source_kind='generated' AND r.status<>'archived'
  AND p.status='completed' AND btrim(coalesce(audio.url,''))<>''
ON CONFLICT (release_id, asset_type) DO UPDATE SET
  file_name=EXCLUDED.file_name, storage_bucket=EXCLUDED.storage_bucket,
  storage_path=EXCLUDED.storage_path, public_url=EXCLUDED.public_url,
  content_type=EXCLUDED.content_type, validation_status='valid', updated_at=now();

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
