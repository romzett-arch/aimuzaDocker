ALTER TABLE public.silk_releases
  ADD COLUMN IF NOT EXISTS user_request_type text CHECK (user_request_type IS NULL OR user_request_type IN ('editing', 'deletion')),
  ADD COLUMN IF NOT EXISTS user_request_message text,
  ADD COLUMN IF NOT EXISTS user_request_status text CHECK (user_request_status IS NULL OR user_request_status IN ('open', 'approved', 'declined')),
  ADD COLUMN IF NOT EXISTS user_request_at timestamptz,
  ADD COLUMN IF NOT EXISTS user_request_resolved_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_silk_releases_user_request
ON public.silk_releases(user_request_status, user_request_at DESC)
WHERE user_request_status = 'open';

DROP POLICY IF EXISTS "Users can update editable own silk releases" ON public.silk_releases;
CREATE POLICY "Users can update editable own silk releases"
ON public.silk_releases FOR UPDATE
USING (auth.uid() = user_id AND status IN ('draft', 'ready', 'needs_changes', 'rejected'))
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can manage editable own silk assets" ON public.silk_release_assets;
CREATE POLICY "Users can manage editable own silk assets"
ON public.silk_release_assets FOR ALL
USING (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes', 'rejected')
  )
)
WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes', 'rejected')
  )
);

CREATE OR REPLACE FUNCTION public.request_silk_release_action(
  p_release_id uuid,
  p_action text,
  p_message text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_release public.silk_releases%ROWTYPE;
  v_message text := btrim(coalesce(p_message, ''));
  v_title text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  IF p_action NOT IN ('editing', 'deletion') THEN
    RAISE EXCEPTION 'Неизвестный тип запроса';
  END IF;

  IF v_message = '' THEN
    RAISE EXCEPTION 'Укажите комментарий к запросу';
  END IF;

  SELECT *
  INTO v_release
  FROM public.silk_releases
  WHERE id = p_release_id
    AND user_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Релиз не найден';
  END IF;

  UPDATE public.silk_releases
  SET
    user_request_type = p_action,
    user_request_message = v_message,
    user_request_status = 'open',
    user_request_at = now(),
    user_request_resolved_at = NULL,
    updated_at = now()
  WHERE id = p_release_id;

  v_title := CASE
    WHEN p_action = 'editing' THEN 'Запрос редактирования релиза'
    ELSE 'Запрос удаления релиза'
  END;

  INSERT INTO public.silk_release_comments (release_id, author_id, is_admin_note, body)
  VALUES (p_release_id, v_user_id, false, v_title || ': ' || v_message);

  INSERT INTO public.silk_release_events (release_id, actor_id, event_type, payload)
  VALUES (
    p_release_id,
    v_user_id,
    CASE WHEN p_action = 'editing' THEN 'editing_requested' ELSE 'deletion_requested' END,
    jsonb_build_object('message', v_message)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_silk_release_action(uuid, text, text) TO authenticated;
