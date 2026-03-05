-- ============================================
-- Maintenance Mode: Server-Side Protection
-- Blocks ALL write operations for non-admin, non-whitelisted users during maintenance
-- ============================================

-- 1. Core check: is maintenance active?
CREATE OR REPLACE FUNCTION public.is_maintenance_active()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT lower(value) = 'true' FROM public.settings WHERE key = 'maintenance_mode'),
    false
  )
$$;

-- 2. Combined check: can this user write during maintenance?
--    Returns TRUE if: maintenance is OFF, OR user is admin, OR user is whitelisted
CREATE OR REPLACE FUNCTION public.can_write_during_maintenance()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT is_maintenance_active()
      OR is_admin(auth.uid())
      OR is_maintenance_whitelisted(auth.uid())
$$;

-- 3. Imperative check: raises exception if blocked
CREATE OR REPLACE FUNCTION public.check_maintenance_access()
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF is_maintenance_active()
     AND NOT is_admin(auth.uid())
     AND NOT is_maintenance_whitelisted(auth.uid())
  THEN
    RAISE EXCEPTION 'Service is under maintenance'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- 4. Block registration during maintenance
--    Restructured: maintenance check is OUTSIDE the exception handler
--    so it propagates up and rolls back the auth.users INSERT
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Block new registrations during maintenance (fail-closed)
  IF is_maintenance_active() THEN
    RAISE EXCEPTION 'Registration is blocked during maintenance'
      USING ERRCODE = 'P0001';
  END IF;

  -- Normal profile creation with error handling
  BEGIN
    INSERT INTO public.profiles (user_id, username, balance)
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
      100
    )
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user profile creation failed for %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

-- 5. Grant execute permissions
GRANT EXECUTE ON FUNCTION public.is_maintenance_active() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_write_during_maintenance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_maintenance_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_maintenance_active() TO service_role;
GRANT EXECUTE ON FUNCTION public.can_write_during_maintenance() TO service_role;
GRANT EXECUTE ON FUNCTION public.check_maintenance_access() TO service_role;

-- ============================================
-- 6. RESTRICTIVE RLS policies on user-facing tables
--    These are AND-ed with existing permissive policies,
--    so admins/whitelisted users still pass (via can_write_during_maintenance)
-- ============================================

-- Helper: adds maintenance block for INSERT, UPDATE, DELETE on a table
-- We create 3 policies per table (INSERT, UPDATE, DELETE) to not affect SELECT

-- ── tracks ──
CREATE POLICY "maintenance_block_insert" ON public.tracks AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.tracks AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.tracks AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── profiles (UPDATE only — INSERT is via trigger) ──
CREATE POLICY "maintenance_block_update" ON public.profiles AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── track_comments ──
CREATE POLICY "maintenance_block_insert" ON public.track_comments AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.track_comments AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.track_comments AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── track_likes ──
CREATE POLICY "maintenance_block_insert" ON public.track_likes AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.track_likes AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── comment_likes ──
CREATE POLICY "maintenance_block_insert" ON public.comment_likes AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.comment_likes AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── gallery_items ──
CREATE POLICY "maintenance_block_insert" ON public.gallery_items AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.gallery_items AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.gallery_items AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── playlists ──
CREATE POLICY "maintenance_block_insert" ON public.playlists AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.playlists AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.playlists AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── playlist_tracks ──
CREATE POLICY "maintenance_block_insert" ON public.playlist_tracks AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.playlist_tracks AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.playlist_tracks AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── user_follows ──
CREATE POLICY "maintenance_block_insert" ON public.user_follows AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.user_follows AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── generated_lyrics ──
CREATE POLICY "maintenance_block_insert" ON public.generated_lyrics AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.generated_lyrics AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── user_prompts ──
CREATE POLICY "maintenance_block_insert" ON public.user_prompts AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.user_prompts AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.user_prompts AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── audio_separations ──
CREATE POLICY "maintenance_block_insert" ON public.audio_separations AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.audio_separations AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── track_addons ──
CREATE POLICY "maintenance_block_insert" ON public.track_addons AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.track_addons AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── track_deposits ──
CREATE POLICY "maintenance_block_insert" ON public.track_deposits AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.track_deposits AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── track_promotions ──
CREATE POLICY "maintenance_block_insert" ON public.track_promotions AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ── promo_videos ──
CREATE POLICY "maintenance_block_insert" ON public.promo_videos AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.promo_videos AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── track_reactions ──
CREATE POLICY "maintenance_block_insert" ON public.track_reactions AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.track_reactions AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── reposts ──
CREATE POLICY "maintenance_block_insert" ON public.reposts AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.reposts AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── messages ──
CREATE POLICY "maintenance_block_insert" ON public.messages AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_update" ON public.messages AS RESTRICTIVE
  FOR UPDATE TO authenticated USING (can_write_during_maintenance());

-- ── notifications (user-created, e.g. marking as read is OK — only INSERT blocked) ──
CREATE POLICY "maintenance_block_insert" ON public.notifications AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ── user_blocks ──
CREATE POLICY "maintenance_block_insert" ON public.user_blocks AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());
CREATE POLICY "maintenance_block_delete" ON public.user_blocks AS RESTRICTIVE
  FOR DELETE TO authenticated USING (can_write_during_maintenance());

-- ── bug_reports ──
CREATE POLICY "maintenance_block_insert" ON public.bug_reports AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ── support_tickets ──
CREATE POLICY "maintenance_block_insert" ON public.support_tickets AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ── contest_entries ──
CREATE POLICY "maintenance_block_insert" ON public.contest_entries AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ── contest_votes ──
CREATE POLICY "maintenance_block_insert" ON public.contest_votes AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (can_write_during_maintenance());

-- ============================================
-- Comments
-- ============================================
COMMENT ON FUNCTION public.is_maintenance_active()
IS 'Returns true when maintenance mode is enabled';
COMMENT ON FUNCTION public.can_write_during_maintenance()
IS 'Returns true if user can write (maintenance off, or user is admin/whitelisted)';
COMMENT ON FUNCTION public.check_maintenance_access()
IS 'Raises exception if maintenance is active and caller is not admin/whitelisted';
