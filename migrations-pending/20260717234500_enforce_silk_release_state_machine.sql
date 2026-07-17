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

  IF NEW.request_type = 'editing' AND v_release.status NOT IN ('submitted', 'voting', 'approved') THEN
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

