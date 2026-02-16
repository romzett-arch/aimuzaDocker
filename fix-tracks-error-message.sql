-- Add error_message column to tracks
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS error_message text;

-- Fix the stuck track: it's uploaded+rejected but has status=pending
-- Set its status to completed so the polling stops picking it up
UPDATE public.tracks
SET status = 'completed'
WHERE id = '9c6da781-a5af-4399-b4b5-eb2a5fdcd505'
  AND status = 'pending'
  AND moderation_status = 'rejected';
