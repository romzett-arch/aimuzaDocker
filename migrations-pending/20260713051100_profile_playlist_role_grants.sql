-- Supabase API roles need table privileges before playlist RLS policies can apply.
GRANT SELECT ON public.playlists TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.playlists TO authenticated;
