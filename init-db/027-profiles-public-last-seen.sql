-- Add last_seen_at to profiles_public for online status fallback
-- ProfileHeader and useOnlineFriends need last_seen_at to show "В сети" when < 2 min ago

DROP VIEW IF EXISTS public.profiles_public;

CREATE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT
  p.id,
  p.user_id,
  p.username,
  p.avatar_url,
  p.cover_url,
  p.bio,
  p.social_links,
  p.followers_count,
  p.following_count,
  p.last_seen_at,
  p.created_at,
  p.updated_at
FROM public.profiles p
WHERE 
  public.is_admin(auth.uid())
  OR
  NOT EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = p.user_id
      AND ur.role = 'super_admin'
  );

GRANT SELECT ON public.profiles_public TO authenticated;
