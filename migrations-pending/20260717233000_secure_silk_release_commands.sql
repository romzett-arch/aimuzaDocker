CREATE OR REPLACE FUNCTION public.submit_silk_release(p_release_id uuid)
RETURNS public.silk_releases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_from_status text;
  v_now timestamptz := now();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  SELECT * INTO v_release
  FROM public.silk_releases
  WHERE id = p_release_id AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  IF v_release.status NOT IN ('draft', 'ready', 'needs_changes', 'rejected') THEN
    RAISE EXCEPTION 'Релиз нельзя отправить из текущего статуса';
  END IF;
  IF btrim(v_release.title) = '' OR btrim(v_release.artist_name) = ''
     OR btrim(coalesce(v_release.genre, '')) = '' OR btrim(v_release.music_author) = ''
     OR btrim(v_release.lyrics_author) = '' THEN
    RAISE EXCEPTION 'Заполните обязательные поля релиза';
  END IF;
  IF NOT (
    coalesce((v_release.metadata #>> '{legal_confirmations,not_cover_or_third_party_track}')::boolean, false)
    AND coalesce((v_release.metadata #>> '{legal_confirmations,owns_lyrics_rights}')::boolean, false)
    AND coalesce((v_release.metadata #>> '{legal_confirmations,owns_or_generated_music_rights}')::boolean, false)
    AND coalesce((v_release.metadata #>> '{legal_confirmations,no_profanity_or_prohibited_content}')::boolean, false)
  ) THEN
    RAISE EXCEPTION 'Подтвердите права и требования к контенту';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY['master_wav', 'reference_mp3', 'cover_art', 'package_zip']) required_type
    WHERE NOT EXISTS (
      SELECT 1 FROM public.silk_release_assets asset
      WHERE asset.release_id = p_release_id
        AND asset.user_id = v_user_id
        AND asset.asset_type = required_type
        AND asset.validation_status = 'valid'
        AND coalesce(asset.file_size, 0) > 0
        AND btrim(asset.storage_path) <> ''
    )
  ) THEN
    RAISE EXCEPTION 'Загрузите WAV, MP3, обложку и архив релиза';
  END IF;

  v_from_status := v_release.status;

  UPDATE public.silk_releases
  SET status = 'submitted', submitted_at = v_now, admin_note = NULL, updated_at = v_now
  WHERE id = p_release_id
  RETURNING * INTO v_release;

  INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
  VALUES (p_release_id, v_user_id, 'submitted', v_from_status, 'submitted', '{}'::jsonb);

  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  SELECT DISTINCT role_row.user_id, 'system', 'Новый релиз для лейбла',
    coalesce(v_release.artist_name, 'Исполнитель') || ' отправил трек «' || v_release.title || '» в релиз.',
    v_user_id, 'silk_release', p_release_id, '/admin/distribution', '{"section":"distribution"}'::jsonb
  FROM public.user_roles role_row
  WHERE role_row.role::text IN ('admin', 'super_admin');

  RETURN v_release;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_silk_release_action(
  p_release_id uuid,
  p_action text,
  p_message text
)
RETURNS public.silk_release_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_request public.silk_release_requests%ROWTYPE;
  v_message text := btrim(coalesce(p_message, ''));
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF p_action NOT IN ('editing', 'deletion') THEN RAISE EXCEPTION 'Неизвестный тип запроса'; END IF;
  IF v_message = '' THEN RAISE EXCEPTION 'Укажите комментарий к запросу'; END IF;

  SELECT * INTO v_release FROM public.silk_releases
  WHERE id = p_release_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  IF EXISTS (SELECT 1 FROM public.silk_release_requests WHERE release_id = p_release_id AND status = 'open') THEN
    RAISE EXCEPTION 'По релизу уже есть открытый запрос';
  END IF;

  INSERT INTO public.silk_release_requests(release_id, user_id, request_type, message, status)
  VALUES (p_release_id, v_user_id, p_action, v_message, 'open')
  RETURNING * INTO v_request;

  INSERT INTO public.silk_release_comments(release_id, author_id, is_admin_note, body)
  VALUES (p_release_id, v_user_id, false,
    CASE WHEN p_action = 'editing' THEN 'Запрос редактирования релиза: ' ELSE 'Запрос удаления релиза: ' END || v_message);
  INSERT INTO public.silk_release_events(release_id, actor_id, event_type, payload)
  VALUES (p_release_id, v_user_id,
    CASE WHEN p_action = 'editing' THEN 'editing_requested' ELSE 'deletion_requested' END,
    jsonb_build_object('message', v_message));
  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  SELECT DISTINCT role_row.user_id, 'system',
    CASE WHEN p_action = 'editing' THEN 'Запрос редактирования релиза' ELSE 'Запрос удаления релиза' END,
    v_release.title || ': ' || v_message, v_user_id, 'silk_release', p_release_id,
    '/admin/distribution', '{"section":"distribution"}'::jsonb
  FROM public.user_roles role_row WHERE role_row.role::text IN ('admin', 'super_admin');

  RETURN v_request;
END;
$$;

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
  IF p_status NOT IN ('needs_changes', 'voting', 'approved', 'sent_to_silk', 'live', 'rejected', 'archived') THEN
    RAISE EXCEPTION 'Неизвестный статус релиза';
  END IF;
  IF p_status IN ('needs_changes', 'rejected') AND btrim(coalesce(p_admin_note, '')) = '' THEN
    RAISE EXCEPTION 'Укажите причину решения';
  END IF;

  SELECT * INTO v_release FROM public.silk_releases WHERE id = p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  v_from_status := v_release.status;

  IF p_status <> 'archived' AND NOT (
    (v_from_status = 'submitted' AND p_status IN ('needs_changes', 'voting', 'approved', 'rejected'))
    OR (v_from_status = 'voting' AND p_status IN ('needs_changes', 'approved', 'rejected'))
    OR (v_from_status = 'approved' AND p_status IN ('needs_changes', 'sent_to_silk', 'rejected'))
    OR (v_from_status = 'sent_to_silk' AND p_status IN ('live', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Недопустимый переход статуса: % → %', v_from_status, p_status;
  END IF;

  IF p_status IN ('approved', 'sent_to_silk') AND EXISTS (
    SELECT 1 FROM unnest(ARRAY['master_wav', 'reference_mp3', 'cover_art', 'package_zip']) required_type
    WHERE NOT EXISTS (
      SELECT 1 FROM public.silk_release_assets asset
      WHERE asset.release_id = p_release_id AND asset.asset_type = required_type
        AND asset.validation_status = 'valid' AND coalesce(asset.file_size, 0) > 0
    )
  ) THEN RAISE EXCEPTION 'Комплект релиза неполный'; END IF;

  UPDATE public.silk_releases SET
    status = p_status,
    admin_note = nullif(btrim(coalesce(p_admin_note, '')), ''),
    reviewed_at = CASE WHEN p_status IN ('needs_changes', 'approved', 'rejected') THEN v_now ELSE reviewed_at END,
    sent_to_silk_at = CASE WHEN p_status = 'sent_to_silk' THEN v_now ELSE sent_to_silk_at END,
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

CREATE OR REPLACE FUNCTION public.admin_resolve_silk_release_request(
  p_release_id uuid,
  p_request_status text,
  p_admin_note text DEFAULT NULL
)
RETURNS public.silk_releases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_request public.silk_release_requests%ROWTYPE;
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin(v_admin_id) THEN RAISE EXCEPTION 'Доступ запрещён'; END IF;
  IF p_request_status NOT IN ('approved', 'declined') THEN RAISE EXCEPTION 'Неизвестный статус запроса'; END IF;
  SELECT * INTO v_release FROM public.silk_releases WHERE id = p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  SELECT * INTO v_request FROM public.silk_release_requests
  WHERE release_id = p_release_id AND status = 'open' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Открытый запрос не найден'; END IF;

  UPDATE public.silk_release_requests SET status = p_request_status,
    admin_note = nullif(btrim(coalesce(p_admin_note, '')), ''), resolved_at = now()
  WHERE id = v_request.id;
  UPDATE public.silk_releases SET admin_note = coalesce(nullif(btrim(coalesce(p_admin_note, '')), ''), admin_note)
  WHERE id = p_release_id RETURNING * INTO v_release;
  INSERT INTO public.silk_release_events(release_id, actor_id, event_type, payload)
  VALUES (p_release_id, v_admin_id, 'user_request_resolved',
    jsonb_build_object('request_type', v_request.request_type, 'request_status', p_request_status, 'admin_note', p_admin_note));
  INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id, link, metadata)
  VALUES (v_release.user_id, 'system',
    CASE WHEN p_request_status = 'approved' THEN 'Запрос одобрен' ELSE 'Запрос отклонён' END,
    coalesce(nullif(btrim(coalesce(p_admin_note, '')), ''), 'Запрос по релизу «' || v_release.title || '» обработан'),
    'silk_release', p_release_id, '/?tab=my-releases',
    jsonb_build_object('request_status', p_request_status, 'request_type', v_request.request_type));
  RETURN v_release;
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_silk_release(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_silk_release_action(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_transition_silk_release(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_silk_release_request(uuid, text, text) TO authenticated;
