CREATE TABLE public.max_chat_blocks (
  max_id text PRIMARY KEY CHECK (max_id ~ '^[1-9][0-9]{0,18}$'),
  blocked_at timestamptz NOT NULL DEFAULT now(),
  blocked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
ALTER TABLE public.max_chat_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.max_chat_blocks FROM PUBLIC, anon, authenticated;

ALTER TABLE public.image_generation_jobs
  ADD COLUMN release_track_id uuid REFERENCES public.tracks(id) ON DELETE SET NULL;

-- Keep the paid cover on previously saved packages when it belongs to one track.
UPDATE public.image_generation_jobs AS image
SET release_track_id = previous.track_id
FROM (
  SELECT user_id, requested_cover_id, min(track_id::text)::uuid AS track_id
  FROM public.release_packages
  WHERE requested_cover_id IS NOT NULL
  GROUP BY user_id, requested_cover_id
  HAVING count(DISTINCT track_id) = 1
) AS previous
WHERE image.user_id = previous.user_id AND image.id = previous.requested_cover_id
  AND image.status = 'completed' AND image.price_rub > 0 AND image.resolution = '3000x3000';
