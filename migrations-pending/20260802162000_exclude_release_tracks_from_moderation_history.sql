CREATE OR REPLACE FUNCTION public.get_admin_moderation_history(
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS TABLE(
  id uuid, track_id uuid, track_user_id uuid, actor_id uuid, action text,
  from_status text, to_status text, reason text, notes text, metadata jsonb,
  created_at timestamptz, track_title text, owner_username text, actor_username text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'moderation')) THEN
    RAISE EXCEPTION 'Требуются права модератора';
  END IF;
  RETURN QUERY
  SELECT e.id, e.track_id, e.track_user_id, e.actor_id, e.action, e.from_status,
    e.to_status, e.reason, e.notes, e.metadata, e.created_at, t.title,
    owner.username, actor.username
  FROM public.moderation_events e
  JOIN public.tracks t ON t.id = e.track_id
  LEFT JOIN public.profiles owner ON owner.user_id = e.track_user_id
  LEFT JOIN public.profiles actor ON actor.user_id = e.actor_id
  WHERE COALESCE(t.is_in_my_releases,false)=false
  ORDER BY e.created_at DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 200)
  OFFSET GREATEST(p_offset, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_moderation_history(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_moderation_history(integer, integer) TO authenticated, service_role;
