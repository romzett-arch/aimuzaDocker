-- Protect author profile playlists at the database boundary.
ALTER TABLE public.playlists ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own or public playlists" ON public.playlists;
DROP POLICY IF EXISTS "Users can insert own playlists" ON public.playlists;
DROP POLICY IF EXISTS "Users can update own playlists" ON public.playlists;
DROP POLICY IF EXISTS "Users can delete own playlists" ON public.playlists;

CREATE POLICY "Users can view own or public playlists" ON public.playlists
FOR SELECT USING (is_public = true OR auth.uid() = user_id);
CREATE POLICY "Users can insert own playlists" ON public.playlists
FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own playlists" ON public.playlists
FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own playlists" ON public.playlists
FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- Maintenance checks narrow owner policies instead of granting writes themselves.
DROP POLICY IF EXISTS maintenance_block_insert ON public.playlists;
DROP POLICY IF EXISTS maintenance_block_update ON public.playlists;
DROP POLICY IF EXISTS maintenance_block_delete ON public.playlists;
CREATE POLICY maintenance_block_insert ON public.playlists AS RESTRICTIVE
FOR INSERT TO authenticated WITH CHECK (public.can_write_during_maintenance());
CREATE POLICY maintenance_block_update ON public.playlists AS RESTRICTIVE
FOR UPDATE TO authenticated USING (public.can_write_during_maintenance()) WITH CHECK (public.can_write_during_maintenance());
CREATE POLICY maintenance_block_delete ON public.playlists AS RESTRICTIVE
FOR DELETE TO authenticated USING (public.can_write_during_maintenance());
