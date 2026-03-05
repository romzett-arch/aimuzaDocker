-- Grant EXECUTE on admin deal RPCs to authenticated (admins checked inside via is_admin)
GRANT EXECUTE ON FUNCTION public.admin_approve_purchase(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_purchase(UUID, TEXT) TO authenticated;

-- RPC for admins to fetch deal content (bypasses RLS for sold/private items)
CREATE OR REPLACE FUNCTION public.admin_get_deal_content(
  p_source_id UUID,
  p_item_type TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  IF p_item_type = 'lyrics' THEN
    SELECT jsonb_build_object(
      'title', li.title,
      'content', li.content,
      'description', li.description
    ) INTO v_result
    FROM public.lyrics_items li
    WHERE li.id = p_source_id;
  ELSIF p_item_type = 'prompt' THEN
    SELECT jsonb_build_object(
      'title', up.title,
      'content', COALESCE(up.lyrics, ''),
      'description', up.description
    ) INTO v_result
    FROM public.user_prompts up
    WHERE up.id = p_source_id;
  ELSE
    RETURN NULL;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_deal_content(UUID, TEXT) TO authenticated;
