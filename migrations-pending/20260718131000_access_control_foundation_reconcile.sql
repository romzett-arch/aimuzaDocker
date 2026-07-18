-- Restore access-control tables required by every authenticated API request.

CREATE TABLE IF NOT EXISTS public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

INSERT INTO public.user_roles(user_id, role)
SELECT profile.user_id, profile.role::text::public.app_role
FROM public.profiles profile
WHERE profile.user_id IS NOT NULL
  AND profile.role::text IN ('user', 'moderator', 'admin', 'super_admin')
ON CONFLICT (user_id, role) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.user_blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  blocked_by uuid NOT NULL,
  reason text NOT NULL,
  blocked_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  unblocked_at timestamptz,
  unblocked_by uuid,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_blocks_user_id ON public.user_blocks(user_id);
CREATE INDEX IF NOT EXISTS idx_user_blocks_active
  ON public.user_blocks(user_id, is_active) WHERE is_active = true;

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own role" ON public.user_roles;
CREATE POLICY "Users can view own role" ON public.user_roles FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
CREATE POLICY "Admins can manage roles" ON public.user_roles FOR ALL TO authenticated
USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Staff can view user blocks" ON public.user_blocks;
CREATE POLICY "Staff can view user blocks" ON public.user_blocks FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS "Admins can manage user blocks" ON public.user_blocks;
CREATE POLICY "Admins can manage user blocks" ON public.user_blocks FOR ALL TO authenticated
USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

GRANT SELECT ON public.user_roles TO authenticated;
GRANT SELECT ON public.user_blocks TO authenticated;
GRANT ALL ON public.user_roles, public.user_blocks TO service_role;
