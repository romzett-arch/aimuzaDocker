-- Add position column for track ordering
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS position integer DEFAULT 0;

-- Set initial positions based on creation order
WITH numbered AS (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) as rn
  FROM public.tracks
)
UPDATE public.tracks t
SET position = n.rn
FROM numbered n
WHERE t.id = n.id;

-- Create index for faster ordering
CREATE INDEX IF NOT EXISTS idx_tracks_position ON public.tracks(user_id, position);
