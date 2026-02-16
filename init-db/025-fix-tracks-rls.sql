-- ═══════════════════════════════════════════════════════════
-- 025: Fix tracks RLS — allow admins/moderators to see ALL tracks
-- Without this, admins cannot see pending/private tracks in moderation
-- ═══════════════════════════════════════════════════════════

-- Admin/Moderator SELECT policy (view all tracks regardless of is_public/user_id)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'tracks' AND policyname = 'Admins can view all tracks'
  ) THEN
    CREATE POLICY "Admins can view all tracks" ON public.tracks
    FOR SELECT USING (
      EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = auth.uid()
        AND role IN ('admin', 'super_admin', 'moderator')
      )
    );
  END IF;
END $$;

-- Admin/Moderator UPDATE policy (change moderation_status, etc.)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'tracks' AND policyname = 'Admins can update all tracks'
  ) THEN
    CREATE POLICY "Admins can update all tracks" ON public.tracks
    FOR UPDATE USING (
      EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = auth.uid()
        AND role IN ('admin', 'super_admin', 'moderator')
      )
    );
  END IF;
END $$;

-- Admin DELETE policy (remove tracks if needed)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'tracks' AND policyname = 'Admins can delete all tracks'
  ) THEN
    CREATE POLICY "Admins can delete all tracks" ON public.tracks
    FOR DELETE USING (
      EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = auth.uid()
        AND role IN ('admin', 'super_admin')
      )
    );
  END IF;
END $$;
