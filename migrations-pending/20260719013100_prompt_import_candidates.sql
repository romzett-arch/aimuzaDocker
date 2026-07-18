CREATE OR REPLACE FUNCTION public.get_importable_prompt_track_ids(p_user_id uuid)
RETURNS TABLE(track_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL OR (v_user_id <> p_user_id AND NOT public.is_admin(v_user_id)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  WITH track_prompts AS (
    SELECT
      track.id,
      btrim(regexp_replace(
        COALESCE(track.description, ''),
        '\s*\[task_id:\s*[^\]]*\]\s*',
        '',
        'g'
      )) AS normalized_description
    FROM public.tracks track
    WHERE track.user_id = p_user_id
  )
  SELECT candidate.id
  FROM track_prompts candidate
  WHERE candidate.normalized_description <> ''
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_prompts prompt
      WHERE prompt.user_id = p_user_id
        AND (
          prompt.track_id = candidate.id
          OR btrim(COALESCE(prompt.description, '')) = candidate.normalized_description
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_importable_prompt_track_ids(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_importable_prompt_track_ids(uuid) TO authenticated;
