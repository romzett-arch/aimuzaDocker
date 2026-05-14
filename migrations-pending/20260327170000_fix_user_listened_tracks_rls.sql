GRANT SELECT, INSERT, UPDATE ON public.user_listened_tracks TO authenticated;

DROP POLICY IF EXISTS "Users can update own listened tracks" ON public.user_listened_tracks;
CREATE POLICY "Users can update own listened tracks"
ON public.user_listened_tracks
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);
