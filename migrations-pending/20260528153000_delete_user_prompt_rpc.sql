CREATE OR REPLACE FUNCTION public.delete_user_prompt(p_prompt_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_prompt_owner uuid;
  v_deleted integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_id
    INTO v_prompt_owner
    FROM public.user_prompts
   WHERE id = p_prompt_id
   FOR UPDATE;

  IF v_prompt_owner IS NULL THEN
    RETURN false;
  END IF;

  IF v_prompt_owner <> v_user_id AND NOT public.is_admin(v_user_id) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  DELETE FROM public.store_items
   WHERE item_type = 'prompt'
     AND source_id = p_prompt_id
     AND seller_id = v_prompt_owner;

  DELETE FROM public.user_prompts
   WHERE id = p_prompt_id
     AND user_id = v_prompt_owner;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_user_prompt(uuid) TO authenticated;
