ALTER TABLE public.release_packages
  ADD COLUMN IF NOT EXISTS requested_title TEXT,
  ADD COLUMN IF NOT EXISTS requested_performer_name TEXT,
  ADD COLUMN IF NOT EXISTS requested_author_name TEXT,
  ADD COLUMN IF NOT EXISTS requested_genre TEXT,
  ADD COLUMN IF NOT EXISTS requested_has_lyrics BOOLEAN,
  ADD COLUMN IF NOT EXISTS requested_include_deposit BOOLEAN;
