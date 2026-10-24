CREATE OR REPLACE FUNCTION public.delete_approved_silk_release(p_release_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_request_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  SELECT *
  INTO v_release
  FROM public.silk_releases
  WHERE id = p_release_id
    AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Релиз не найден';
  END IF;

  IF v_release.status <> 'archived' THEN
    RAISE EXCEPTION 'Релиз должен быть архивирован после одобрения запроса на удаление';
  END IF;

  SELECT id
  INTO v_request_id
  FROM public.silk_release_requests
  WHERE release_id = p_release_id
    AND user_id = v_user_id
    AND request_type = 'deletion'
    AND status = 'approved'
  ORDER BY resolved_at DESC NULLS LAST, created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Нет одобренного запроса на удаление';
  END IF;

  DELETE FROM public.silk_releases
  WHERE id = p_release_id;

  RETURN p_release_id;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_approved_silk_release(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_approved_silk_release(uuid) TO authenticated;
