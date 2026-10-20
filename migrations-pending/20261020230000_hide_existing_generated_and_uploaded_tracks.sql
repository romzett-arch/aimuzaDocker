-- Keep existing generated and uploaded tracks private until their owner explicitly publishes them.
UPDATE public.tracks
SET is_public = false
WHERE is_public IS DISTINCT FROM false
  AND source_type IN ('generated', 'uploaded');
