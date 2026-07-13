CREATE OR REPLACE FUNCTION public.forum_increment_knowledge_views(p_article_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_views integer;
BEGIN
  UPDATE public.forum_knowledge_articles
  SET views_count = views_count + 1
  WHERE id = p_article_id AND status = 'published'
  RETURNING views_count INTO v_views;
  RETURN v_views;
END;
$$;

REVOKE ALL ON FUNCTION public.forum_increment_knowledge_views(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_increment_knowledge_views(uuid) TO anon, authenticated, service_role;
