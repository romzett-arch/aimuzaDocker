ALTER TABLE public.lyrics_deposits
ADD COLUMN IF NOT EXISTS author_name text;

COMMENT ON COLUMN public.lyrics_deposits.author_name IS 'Имя автора, указанное при депонировании';
