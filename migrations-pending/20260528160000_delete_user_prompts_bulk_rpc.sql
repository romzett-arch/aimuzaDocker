-- Батчевое удаление промптов одним RPC (без шквала POST /rest/v1/rpc/delete_user_prompt).

CREATE OR REPLACE FUNCTION public.delete_user_prompts(p_prompt_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_deleted integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_prompt_ids IS NULL OR COALESCE(array_length(p_prompt_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_prompt_ids) AS prompt_id
    GROUP BY prompt_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Prompt list contains duplicates';
  END IF;

  DELETE FROM public.store_items si
   WHERE si.item_type = 'prompt'
     AND si.source_id = ANY (p_prompt_ids)
     AND EXISTS (
       SELECT 1
         FROM public.user_prompts up
        WHERE up.id = si.source_id
          AND (
            up.user_id = v_user_id
            OR public.is_admin(v_user_id)
          )
     );

  DELETE FROM public.user_prompts up
   WHERE up.id = ANY (p_prompt_ids)
     AND (
       up.user_id = v_user_id
       OR public.is_admin(v_user_id)
     );

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_user_prompts(uuid[]) TO authenticated;
