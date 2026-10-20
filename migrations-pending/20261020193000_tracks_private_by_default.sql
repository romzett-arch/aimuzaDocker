-- New tracks are private until their owner explicitly publishes them.
ALTER TABLE public.tracks
  ALTER COLUMN is_public SET DEFAULT false;
