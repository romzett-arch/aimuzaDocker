BEGIN;

ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS content_sha256 text;

ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_content_sha256_check;
ALTER TABLE public.tracks ADD CONSTRAINT tracks_content_sha256_check
  CHECK (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$');

UPDATE public.tracks SET moderation_status = 'none'
WHERE moderation_status IS NULL OR moderation_status NOT IN
  ('none', 'pending', 'copyright_pending', 'voting', 'approved', 'rejected');

ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_moderation_status_check;
ALTER TABLE public.tracks ADD CONSTRAINT tracks_moderation_status_check
  CHECK (moderation_status IN ('none', 'pending', 'copyright_pending', 'voting', 'approved', 'rejected'));

CREATE INDEX IF NOT EXISTS idx_tracks_content_sha256
  ON public.tracks(content_sha256) WHERE content_sha256 IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.moderation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  track_user_id uuid NOT NULL,
  actor_id uuid,
  action text NOT NULL CHECK (action IN (
    'submitted', 'approved', 'rejected', 'copyright_requested',
    'copyright_responded', 'copyright_approved', 'copyright_rejected'
  )),
  from_status text,
  to_status text NOT NULL,
  reason text,
  notes text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_moderation_events_track_created
  ON public.moderation_events(track_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_events_created
  ON public.moderation_events(created_at DESC);

ALTER TABLE public.moderation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff can view moderation events" ON public.moderation_events;
CREATE POLICY "Staff can view moderation events" ON public.moderation_events
  FOR SELECT USING (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'moderation'));

DROP POLICY IF EXISTS "Owners can view own moderation events" ON public.moderation_events;
CREATE POLICY "Owners can view own moderation events" ON public.moderation_events
  FOR SELECT USING (track_user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.enforce_uploaded_track_publication()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.source_type = 'uploaded'
     AND COALESCE(NEW.is_public, false)
     AND NEW.moderation_status <> 'approved' THEN
    RAISE EXCEPTION USING
      MESSAGE = 'Загруженный трек можно опубликовать только после одобрения модератором',
      ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_uploaded_track_publication ON public.tracks;
CREATE TRIGGER trg_enforce_uploaded_track_publication
  BEFORE INSERT OR UPDATE OF is_public, moderation_status, source_type ON public.tracks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_uploaded_track_publication();

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

  SELECT * INTO v_track FROM public.tracks
  WHERE id = p_track_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден'; END IF;
  IF v_track.moderation_status = 'pending' THEN RETURN v_track; END IF;
  IF COALESCE(v_track.moderation_status, 'none') NOT IN ('none', 'rejected') THEN
    RAISE EXCEPTION 'Трек нельзя отправить на модерацию из текущего статуса';
  END IF;
  IF COALESCE(btrim(v_track.audio_url), '') = '' THEN RAISE EXCEPTION 'У трека отсутствует аудиофайл'; END IF;

  v_title := COALESCE(NULLIF(btrim(p_title), ''), NULLIF(btrim(v_track.title), ''));
  IF v_title IS NULL THEN RAISE EXCEPTION 'Укажите название трека'; END IF;
  v_from_status := COALESCE(v_track.moderation_status, 'none');
  v_previous_bypass := current_setting('app.bypass_track_protection', true);
  PERFORM set_config('app.bypass_track_protection', 'true', true);

  UPDATE public.tracks SET
    title = v_title,
    description = CASE WHEN p_description IS NULL THEN description ELSE NULLIF(btrim(p_description), '') END,
    status = 'pending', moderation_status = 'pending', is_public = false,
    moderation_rejection_reason = NULL, moderation_notes = NULL,
    moderation_reviewed_at = NULL, moderation_reviewed_by = NULL, updated_at = now()
  WHERE id = p_track_id RETURNING * INTO v_track;

  INSERT INTO public.moderation_events
    (track_id, track_user_id, actor_id, action, from_status, to_status)
  VALUES (v_track.id, v_track.user_id, v_user_id, 'submitted', v_from_status, 'pending');

  PERFORM set_config('app.bypass_track_protection', COALESCE(v_previous_bypass, 'false'), true);
  RETURN v_track;
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
  IF p_decision NOT IN ('approved', 'rejected') THEN RAISE EXCEPTION 'Некорректное решение модерации'; END IF;

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден'; END IF;
  IF v_track.moderation_status <> p_expected_status THEN
    RAISE EXCEPTION 'Статус трека уже изменился. Обновите список и повторите действие';
  END IF;

  IF p_decision = 'rejected' AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Укажите причину отклонения';
  END IF;

  IF p_decision = 'approved' THEN
    SELECT analysis_status INTO v_health_status FROM public.track_health_reports WHERE track_id = p_track_id;
    IF v_track.copyright_check_status <> 'clean' THEN v_issues := array_append(v_issues, 'проверка авторских прав не завершена'); END IF;
    IF v_track.plagiarism_check_status <> 'clean' THEN v_issues := array_append(v_issues, 'проверка совпадений не завершена'); END IF;
    IF COALESCE(v_health_status, 'missing') <> 'completed' THEN v_issues := array_append(v_issues, 'технический анализ аудио не завершён'); END IF;
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
    UPDATE public.tracks SET moderation_status = 'approved', moderation_reviewed_by = v_actor,
      moderation_reviewed_at = now(), moderation_notes = NULLIF(btrim(p_notes), ''),
      moderation_rejection_reason = NULL, status = 'completed', is_public = true, updated_at = now()
    WHERE id = p_track_id RETURNING * INTO v_track;
  ELSE
    UPDATE public.tracks SET moderation_status = 'rejected', moderation_reviewed_by = v_actor,
      moderation_reviewed_at = now(), moderation_notes = NULLIF(btrim(p_notes), ''),
      moderation_rejection_reason = btrim(p_reason), is_public = false,
      voting_result = CASE WHEN moderation_status = 'voting' THEN 'rejected' ELSE NULL END,
      updated_at = now()
    WHERE id = p_track_id RETURNING * INTO v_track;

    IF v_track.forum_topic_id IS NOT NULL THEN
      UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
    END IF;
  END IF;

  INSERT INTO public.moderation_events
    (track_id, track_user_id, actor_id, action, from_status, to_status, reason, notes, metadata)
  VALUES (v_track.id, v_track.user_id, v_actor, p_decision, p_expected_status, p_decision,
    NULLIF(btrim(p_reason), ''), NULLIF(btrim(p_notes), ''),
    jsonb_build_object('override', p_override, 'issues', to_jsonb(v_issues)));

  INSERT INTO public.notifications(user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (v_track.user_id,
    CASE WHEN p_decision = 'approved' THEN 'track_approved' ELSE 'track_rejected' END,
    CASE WHEN p_decision = 'approved' THEN 'Трек одобрен!' ELSE 'Трек отклонён' END,
    CASE WHEN p_decision = 'approved'
      THEN format('Ваш трек "%s" прошёл модерацию и опубликован.', v_track.title)
      ELSE format('Ваш трек "%s" не прошёл модерацию. Причина: %s', v_track.title, btrim(p_reason)) END,
    v_actor, 'track', v_track.id);

  PERFORM set_config('app.bypass_track_protection', COALESCE(v_previous_bypass, 'false'), true);
  RETURN v_track;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_track_copyright_evidence(
  p_track_id uuid, p_reason text, p_plagiarism_data jsonb DEFAULT NULL
)
RETURNS public.copyright_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_actor uuid := auth.uid(); v_track public.tracks%ROWTYPE; v_request public.copyright_requests%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT (public.is_admin(v_actor) OR public.has_permission(v_actor, 'moderation')) THEN RAISE EXCEPTION 'Требуются права модератора'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Укажите причину запроса'; END IF;
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Трек не найден'; END IF;
  IF v_track.moderation_status NOT IN ('pending', 'voting') THEN RAISE EXCEPTION 'Запрос нельзя создать из текущего статуса'; END IF;
  IF EXISTS (SELECT 1 FROM public.copyright_requests WHERE track_id=p_track_id AND status IN ('pending','responded')) THEN RAISE EXCEPTION 'По треку уже есть активный запрос'; END IF;
  INSERT INTO public.copyright_requests(track_id,user_id,moderator_id,request_reason,plagiarism_data)
  VALUES (p_track_id,v_track.user_id,v_actor,btrim(p_reason),p_plagiarism_data) RETURNING * INTO v_request;
  UPDATE public.tracks SET moderation_status='copyright_pending',is_public=false,updated_at=now() WHERE id=p_track_id;
  INSERT INTO public.moderation_events(track_id,track_user_id,actor_id,action,from_status,to_status,reason)
  VALUES(p_track_id,v_track.user_id,v_actor,'copyright_requested',v_track.moderation_status,'copyright_pending',btrim(p_reason));
  INSERT INTO public.notifications(user_id,type,title,message,actor_id,target_type,target_id)
  VALUES(v_track.user_id,'copyright_request','Запрос подтверждения авторских прав',format('Предоставьте доказательства авторских прав для трека "%s".',v_track.title),v_actor,'copyright_request',v_request.id);
  RETURN v_request;
END; $$;

CREATE OR REPLACE FUNCTION public.respond_copyright_request(
  p_request_id uuid, p_response text, p_documents text[] DEFAULT ARRAY[]::text[]
)
RETURNS public.copyright_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.copyright_requests%ROWTYPE; v_title text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF COALESCE(btrim(p_response),'')='' THEN RAISE EXCEPTION 'Введите ответ'; END IF;
  SELECT * INTO v_request FROM public.copyright_requests WHERE id=p_request_id AND user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Запрос не найден'; END IF;
  IF v_request.status<>'pending' THEN RAISE EXCEPTION 'На этот запрос уже был дан ответ'; END IF;
  UPDATE public.copyright_requests SET status='responded',user_response=btrim(p_response),user_documents=COALESCE(p_documents,ARRAY[]::text[]),responded_at=now()
  WHERE id=p_request_id RETURNING * INTO v_request;
  SELECT title INTO v_title FROM public.tracks WHERE id=v_request.track_id;
  INSERT INTO public.moderation_events(track_id,track_user_id,actor_id,action,from_status,to_status)
  VALUES(v_request.track_id,v_request.user_id,v_actor,'copyright_responded','copyright_pending','copyright_pending');
  INSERT INTO public.notifications(user_id,type,title,message,actor_id,target_type,target_id)
  VALUES(v_request.moderator_id,'copyright_response','Получен ответ на запрос авторских прав',format('Получен ответ по треку "%s".',v_title),v_actor,'copyright_request',v_request.id);
  RETURN v_request;
END; $$;

CREATE OR REPLACE FUNCTION public.resolve_copyright_request(
  p_request_id uuid, p_decision text, p_notes text DEFAULT NULL
)
RETURNS public.copyright_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.copyright_requests%ROWTYPE; v_track public.tracks%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT (public.is_admin(v_actor) OR public.has_permission(v_actor,'moderation')) THEN RAISE EXCEPTION 'Требуются права модератора'; END IF;
  IF p_decision NOT IN ('approved','rejected') THEN RAISE EXCEPTION 'Некорректное решение'; END IF;
  SELECT * INTO v_request FROM public.copyright_requests WHERE id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Запрос не найден'; END IF;
  IF v_request.status<>'responded' THEN RAISE EXCEPTION 'Запрос ещё не готов к решению или уже закрыт'; END IF;
  SELECT * INTO v_track FROM public.tracks WHERE id=v_request.track_id FOR UPDATE;
  UPDATE public.copyright_requests SET status=p_decision,moderator_decision=NULLIF(btrim(p_notes),''),resolved_at=now(),resolved_by=v_actor
  WHERE id=p_request_id RETURNING * INTO v_request;
  IF p_decision='approved' THEN
    UPDATE public.tracks SET moderation_status='pending',copyright_check_status='clean',plagiarism_check_status='clean',is_public=false,updated_at=now() WHERE id=v_track.id;
  ELSE
    UPDATE public.tracks SET moderation_status='rejected',moderation_rejection_reason='Не удалось подтвердить авторские права',moderation_reviewed_by=v_actor,moderation_reviewed_at=now(),is_public=false,updated_at=now() WHERE id=v_track.id;
  END IF;
  INSERT INTO public.moderation_events(track_id,track_user_id,actor_id,action,from_status,to_status,notes)
  VALUES(v_track.id,v_track.user_id,v_actor,CASE WHEN p_decision='approved' THEN 'copyright_approved' ELSE 'copyright_rejected' END,'copyright_pending',CASE WHEN p_decision='approved' THEN 'pending' ELSE 'rejected' END,NULLIF(btrim(p_notes),''));
  INSERT INTO public.notifications(user_id,type,title,message,actor_id,target_type,target_id)
  VALUES(v_track.user_id,CASE WHEN p_decision='approved' THEN 'copyright_approved' ELSE 'copyright_rejected' END,CASE WHEN p_decision='approved' THEN 'Авторские права подтверждены' ELSE 'Авторские права не подтверждены' END,format('Решение по треку "%s" принято.',v_track.title),v_actor,'track',v_track.id);
  RETURN v_request;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_moderation_stats()
RETURNS TABLE(pending bigint, voting bigint, approved bigint, rejected bigint, total bigint, responded_copyright bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(),'moderation')) THEN RAISE EXCEPTION 'Требуются права модератора'; END IF;
  RETURN QUERY SELECT
    count(*) FILTER(WHERE moderation_status='pending'), count(*) FILTER(WHERE moderation_status='voting'),
    count(*) FILTER(WHERE moderation_status='approved'), count(*) FILTER(WHERE moderation_status='rejected'),
    count(*) FILTER(WHERE moderation_status IN ('pending','voting','approved','rejected')),
    (SELECT count(*) FROM public.copyright_requests WHERE status='responded')
  FROM public.tracks WHERE COALESCE(is_in_my_releases,false)=false;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_moderation_history(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid,track_id uuid,track_user_id uuid,actor_id uuid,action text,from_status text,to_status text,reason text,notes text,metadata jsonb,created_at timestamptz,track_title text,owner_username text,actor_username text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(),'moderation')) THEN RAISE EXCEPTION 'Требуются права модератора'; END IF;
  RETURN QUERY SELECT e.id,e.track_id,e.track_user_id,e.actor_id,e.action,e.from_status,e.to_status,e.reason,e.notes,e.metadata,e.created_at,t.title,owner.username,actor.username
  FROM public.moderation_events e JOIN public.tracks t ON t.id=e.track_id
  LEFT JOIN public.profiles owner ON owner.user_id=e.track_user_id LEFT JOIN public.profiles actor ON actor.user_id=e.actor_id
  ORDER BY e.created_at DESC LIMIT LEAST(GREATEST(p_limit,1),200) OFFSET GREATEST(p_offset,0);
END; $$;

REVOKE ALL ON FUNCTION public.submit_track_for_moderation(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.moderate_track(uuid,text,text,text,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_track_copyright_evidence(uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_copyright_request(uuid,text,text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_copyright_request(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_moderation_stats() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_moderation_history(integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_track_for_moderation(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.moderate_track(uuid,text,text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_track_copyright_evidence(uuid,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_copyright_request(uuid,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_copyright_request(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_moderation_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_moderation_history(integer,integer) TO authenticated;

COMMIT;
