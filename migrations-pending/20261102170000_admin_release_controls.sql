-- Administrative release controls; records and events are retained for audit.
ALTER TABLE public.silk_releases DROP CONSTRAINT IF EXISTS silk_releases_status_check;
ALTER TABLE public.silk_releases ADD CONSTRAINT silk_releases_status_check CHECK (
  status IN ('draft','ready','submitted','needs_changes','approved','sending',
             'sent_to_silk','live','rejected','archived','suspended','withdrawn')
);

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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_from text;
  v_to text;
  v_label text;
  v_reason text := nullif(btrim(p_reason), '');
BEGIN
  IF v_actor IS NULL OR NOT coalesce(public.is_admin(v_actor), false) THEN
    RAISE EXCEPTION 'Доступ запрещён';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину для уведомления пользователя'; END IF;
  IF p_action IS NULL OR p_action NOT IN ('suspend','withdraw','delete','resume') THEN
    RAISE EXCEPTION 'Неизвестное действие';
  END IF;
  SELECT * INTO v_release FROM public.silk_releases WHERE id=p_release_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Релиз не найден'; END IF;
  v_from := v_release.status;
  v_to := CASE p_action WHEN 'suspend' THEN 'suspended' WHEN 'withdraw' THEN 'withdrawn'
          WHEN 'delete' THEN 'archived' ELSE v_release.metadata->>'admin_previous_status' END;
  v_label := CASE p_action WHEN 'suspend' THEN 'приостановлен' WHEN 'withdraw' THEN 'отозван'
             WHEN 'delete' THEN 'удалён из очереди' ELSE 'возобновлён' END;
  IF p_action='resume' AND (v_from <> 'suspended' OR v_to IS NULL OR
     v_to NOT IN ('draft','ready','submitted','needs_changes','approved','sending','sent_to_silk','live','rejected','archived','withdrawn')) THEN
    RAISE EXCEPTION 'Этот релиз нельзя возобновить';
  END IF;
  IF v_to = v_from THEN RAISE EXCEPTION 'Действие уже выполнено'; END IF;
  UPDATE public.silk_releases SET
    status=v_to, admin_note=v_reason, updated_at=now(),
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'admin_previous_status', v_from, 'admin_action', p_action, 'admin_action_at', now())
  WHERE id=p_release_id RETURNING * INTO v_release;

  IF p_action IN ('delete','withdraw') THEN
    UPDATE public.silk_release_requests SET status='declined', admin_note=v_reason, resolved_at=now()
    WHERE release_id=p_release_id AND status='open';
  END IF;
  INSERT INTO public.silk_release_events(release_id,actor_id,event_type,from_status,to_status,payload)
  VALUES(p_release_id,v_actor,'admin_action',v_from,v_to,jsonb_build_object('action',p_action,'reason',v_reason));
  INSERT INTO public.notifications(user_id,type,title,message,actor_id,target_type,target_id,link,metadata)
  VALUES(v_release.user_id,'system','Релиз ' || v_label,
    'Релиз «' || v_release.title || '» ' || v_label || '. Причина: ' || v_reason,
    v_actor,'silk_release',p_release_id,'/?tab=my-releases',
    jsonb_build_object('status',v_to,'action',p_action,'reason',v_reason));
  RETURN v_release;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_manage_silk_release(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_manage_silk_release(uuid,text,text) TO authenticated;
