
-- Update profiles_public view:
-- Admins/super_admins see ALL profiles (including super_admin)
-- Regular users see everyone EXCEPT super_admin
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
WHERE 
  -- Admins see everyone
  public.is_admin(auth.uid())
  OR
  -- Non-admins see everyone except super_admin users
  NOT EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = p.user_id
      AND ur.role = 'super_admin'
  );
