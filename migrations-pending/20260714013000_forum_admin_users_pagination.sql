-- Server-side admin user search and pagination. This avoids truncating the
-- management list before filtering by profile name.

CREATE OR REPLACE FUNCTION public.forum_admin_list_users(
  p_search text DEFAULT '',
  p_filter text DEFAULT 'all',
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  user_id uuid,
  username text,
  avatar_url text,
  trust_level integer,
  reputation_score integer,
  topics_created integer,
  posts_created integer,
  warnings_count integer,
  is_muted boolean,
  muted_until timestamptz,
  is_silenced boolean,
  silenced_until timestamptz,
  is_banned boolean,
  banned_until timestamptz,
  ban_reason text,
  created_at timestamptz,
  last_post_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  IF p_filter NOT IN ('all', 'muted', 'banned', 'warned') THEN RAISE EXCEPTION 'Некорректный фильтр'; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 OR p_offset < 0 THEN RAISE EXCEPTION 'Некорректная пагинация'; END IF;

  RETURN QUERY
  SELECT
    s.user_id,
    p.username,
    p.avatar_url,
    COALESCE(s.trust_level, 0),
    COALESCE(s.reputation_score, 0),
    COALESCE(s.topics_created, 0),
    COALESCE(s.posts_created, 0),
    COALESCE(s.warnings_count, 0),
    COALESCE(s.is_muted, false),
    s.muted_until,
    COALESCE(s.is_silenced, false),
    s.silenced_until,
    COALESCE(s.is_banned, false),
    s.banned_until,
    s.ban_reason,
    s.joined_at,
    s.last_post_at,
    count(*) OVER ()
  FROM public.forum_user_stats s
  LEFT JOIN public.profiles_public p ON p.user_id = s.user_id
  WHERE (trim(COALESCE(p_search, '')) = '' OR p.username ILIKE '%' || trim(p_search) || '%')
    AND (p_filter = 'all'
      OR (p_filter = 'muted' AND s.is_muted)
      OR (p_filter = 'banned' AND s.is_banned)
      OR (p_filter = 'warned' AND s.warnings_count > 0))
  ORDER BY s.reputation_score DESC, s.joined_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.forum_admin_list_users(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_admin_list_users(text, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_admin_list_users(text, text, integer, integer) TO authenticated;
