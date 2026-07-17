BEGIN;

-- Restore only missing identities that already authored public forum content.
-- No welcome balance or registration side effects are created by this repair.
INSERT INTO public.profiles (
  user_id, username, display_name, email, balance, role, is_super_admin, is_protected
)
SELECT
  u.id,
  COALESCE(
    NULLIF(trim(u.raw_user_meta_data->>'username'), ''),
    NULLIF(trim(u.raw_user_meta_data->>'display_name'), ''),
    split_part(u.email, '@', 1),
    'Пользователь'
  ),
  COALESCE(
    NULLIF(trim(u.raw_user_meta_data->>'display_name'), ''),
    NULLIF(trim(u.raw_user_meta_data->>'username'), ''),
    split_part(u.email, '@', 1),
    'Пользователь'
  ),
  u.email,
  0,
  COALESCE((
    SELECT ur.role::text
    FROM public.user_roles ur
    WHERE ur.user_id = u.id
    ORDER BY CASE ur.role::text
      WHEN 'super_admin' THEN 0 WHEN 'admin' THEN 1 WHEN 'moderator' THEN 2 ELSE 3
    END
    LIMIT 1
  ), 'user'),
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = u.id AND ur.role = 'super_admin'
  ),
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = u.id AND ur.role = 'super_admin'
  )
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = u.id)
  AND (
    EXISTS (SELECT 1 FROM public.forum_topics t WHERE t.user_id = u.id)
    OR EXISTS (SELECT 1 FROM public.forum_posts fp WHERE fp.user_id = u.id)
  )
ON CONFLICT (user_id) DO NOTHING;

-- The general public profile view intentionally hides super administrators.
-- This forum-specific view exposes only an author's public name and avatar,
-- and only after that account has published forum content.
CREATE OR REPLACE VIEW public.forum_author_profiles
WITH (security_barrier = true)
AS
SELECT p.user_id, p.username, p.avatar_url
FROM public.profiles p
WHERE EXISTS (SELECT 1 FROM public.forum_topics t WHERE t.user_id = p.user_id)
   OR EXISTS (SELECT 1 FROM public.forum_posts fp WHERE fp.user_id = p.user_id);

REVOKE ALL ON public.forum_author_profiles FROM PUBLIC;
GRANT SELECT ON public.forum_author_profiles TO anon, authenticated, service_role;

COMMIT;
