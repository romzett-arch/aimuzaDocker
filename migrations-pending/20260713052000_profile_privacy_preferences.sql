ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS show_online_status boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_profile_stats boolean NOT NULL DEFAULT true;

CREATE OR REPLACE VIEW public.profiles_public
WITH (security_invoker = true)
AS
SELECT p.id, p.user_id, p.username, p.avatar_url, p.cover_url, p.bio,
       p.social_links, p.followers_count, p.following_count, p.last_seen_at,
       p.created_at, p.updated_at, p.show_online_status, p.show_profile_stats
FROM public.profiles p
WHERE public.is_admin(auth.uid())
   OR NOT EXISTS (
     SELECT 1 FROM public.user_roles ur
     WHERE ur.user_id = p.user_id AND ur.role = 'super_admin'::public.app_role
   );

GRANT SELECT ON public.profiles_public TO anon, authenticated;
