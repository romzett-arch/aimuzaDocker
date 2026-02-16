ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS lyrics text;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS genre_id text;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS vocal_type_id text;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS template_id text;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS artist_style_id text;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS uses_count integer DEFAULT 0;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS track_id uuid;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS is_exclusive boolean DEFAULT false;
ALTER TABLE public.user_prompts ADD COLUMN IF NOT EXISTS license_type text;

ALTER TABLE public.user_prompts ALTER COLUMN prompt_text DROP NOT NULL;
ALTER TABLE public.user_prompts ALTER COLUMN prompt_text SET DEFAULT '';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_prompts_track_id_fkey'
  ) THEN
    ALTER TABLE public.user_prompts
      ADD CONSTRAINT user_prompts_track_id_fkey
      FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE SET NULL;
  END IF;
END $$;
