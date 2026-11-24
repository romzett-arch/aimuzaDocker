-- Some installations have playlists and playlist_tracks without the original
-- likes relation or the triggers that maintain counters on playlists.
CREATE TABLE IF NOT EXISTS public.playlist_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  playlist_id uuid NOT NULL REFERENCES public.playlists(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT unique_playlist_like UNIQUE (playlist_id, user_id)
);

ALTER TABLE public.playlist_likes ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON public.playlist_likes TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'playlist_likes' AND cmd = 'SELECT') THEN
    CREATE POLICY "Users can read their playlist likes" ON public.playlist_likes
      FOR SELECT TO authenticated USING (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'playlist_likes' AND policyname = 'Users can like playlists') THEN
    CREATE POLICY "Users can like playlists" ON public.playlist_likes
      FOR INSERT TO authenticated WITH CHECK (
        auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.playlists WHERE id = playlist_id)
      );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'playlist_likes' AND policyname = 'Users can unlike playlists') THEN
    CREATE POLICY "Users can unlike playlists" ON public.playlist_likes
      FOR DELETE TO authenticated USING (auth.uid() = user_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.update_playlist_tracks_count()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.playlists SET tracks_count = COALESCE(tracks_count, 0) + 1, updated_at = now()
    WHERE id = NEW.playlist_id;
  ELSE
    UPDATE public.playlists SET tracks_count = GREATEST(COALESCE(tracks_count, 0) - 1, 0), updated_at = now()
    WHERE id = OLD.playlist_id;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.update_playlist_likes_count()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.playlists SET likes_count = COALESCE(likes_count, 0) + 1 WHERE id = NEW.playlist_id;
  ELSE
    UPDATE public.playlists SET likes_count = GREATEST(COALESCE(likes_count, 0) - 1, 0) WHERE id = OLD.playlist_id;
  END IF;
  RETURN NULL;
END $$;

LOCK TABLE public.playlist_tracks, public.playlist_likes IN SHARE ROW EXCLUSIVE MODE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.playlist_tracks'::regclass AND tgname = 'update_playlist_tracks_count_trigger') THEN
    CREATE TRIGGER update_playlist_tracks_count_trigger AFTER INSERT OR DELETE ON public.playlist_tracks
      FOR EACH ROW EXECUTE FUNCTION public.update_playlist_tracks_count();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.playlist_likes'::regclass AND tgname = 'update_playlist_likes_count_trigger') THEN
    CREATE TRIGGER update_playlist_likes_count_trigger AFTER INSERT OR DELETE ON public.playlist_likes
      FOR EACH ROW EXECUTE FUNCTION public.update_playlist_likes_count();
  END IF;
END $$;

WITH tracks AS (SELECT playlist_id, count(*)::integer AS total FROM public.playlist_tracks GROUP BY playlist_id),
     likes AS (SELECT playlist_id, count(*)::integer AS total FROM public.playlist_likes GROUP BY playlist_id),
     totals AS (
       SELECT p.id, COALESCE(tracks.total, 0) AS track_count, COALESCE(likes.total, 0) AS like_count
       FROM public.playlists p LEFT JOIN tracks ON tracks.playlist_id = p.id LEFT JOIN likes ON likes.playlist_id = p.id
     )
UPDATE public.playlists p SET tracks_count = totals.track_count, likes_count = totals.like_count
FROM totals WHERE p.id = totals.id
  AND (p.tracks_count IS DISTINCT FROM totals.track_count OR p.likes_count IS DISTINCT FROM totals.like_count);
