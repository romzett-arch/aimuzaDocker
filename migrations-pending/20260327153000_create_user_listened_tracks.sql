CREATE TABLE IF NOT EXISTS public.user_listened_tracks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  listened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT user_listened_tracks_user_id_track_id_key UNIQUE (user_id, track_id)
);

CREATE INDEX IF NOT EXISTS idx_user_listened_tracks_user_id
  ON public.user_listened_tracks (user_id);

CREATE INDEX IF NOT EXISTS idx_user_listened_tracks_track_id
  ON public.user_listened_tracks (track_id);

ALTER TABLE public.user_listened_tracks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own listened tracks" ON public.user_listened_tracks;
CREATE POLICY "Users can view own listened tracks"
ON public.user_listened_tracks
FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create own listened tracks" ON public.user_listened_tracks;
CREATE POLICY "Users can create own listened tracks"
ON public.user_listened_tracks
FOR INSERT
WITH CHECK (auth.uid() = user_id);
