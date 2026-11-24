-- Restore the original membership constraint on installations that only have
-- the playlist_tracks primary key. Existing memberships are preserved.
CREATE UNIQUE INDEX IF NOT EXISTS unique_playlist_track
  ON public.playlist_tracks (playlist_id, track_id);

CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track
  ON public.playlist_tracks (track_id);
