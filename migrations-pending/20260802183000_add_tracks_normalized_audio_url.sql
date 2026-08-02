ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS normalized_audio_url text;

COMMENT ON COLUMN public.tracks.normalized_audio_url IS
  'Legacy compatibility URL for the normalized master; canonical playback master is master_audio_url.';

