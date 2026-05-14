
-- Hide super_admin users from profiles_public view
-- Super admins will only be visible through direct profiles table (admin panel)
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
  p.created_at,
  p.updated_at
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_roles ur
  WHERE ur.user_id = p.user_id
    AND ur.role = 'super_admin'
);
