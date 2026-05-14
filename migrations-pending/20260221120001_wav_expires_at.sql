-- Add wav_expires_at column for 7-day TTL on WAV files
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS wav_expires_at TIMESTAMPTZ;

-- Backfill: existing WAV files get 7 days from their last update
UPDATE public.tracks 
SET wav_expires_at = updated_at + INTERVAL '7 days' 
WHERE wav_url IS NOT NULL AND wav_expires_at IS NULL;
