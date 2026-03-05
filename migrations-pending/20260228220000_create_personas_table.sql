-- Create/upgrade personas table (idempotent) + suno_audio_id column on tracks
-- Needed for persona creation feature via Suno API

CREATE TABLE IF NOT EXISTS public.personas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    name TEXT NOT NULL,
    avatar_url TEXT,
    source_track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
    clip_start_time NUMERIC NOT NULL DEFAULT 0,
    clip_end_time NUMERIC NOT NULL DEFAULT 30,
    suno_persona_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    is_public BOOLEAN DEFAULT false,
    description TEXT,
    style_tags TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Add missing columns if table already existed with old schema
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS source_track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL;
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS clip_start_time NUMERIC NOT NULL DEFAULT 0;
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS clip_end_time NUMERIC NOT NULL DEFAULT 30;
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS suno_persona_id TEXT;
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS style_tags TEXT;
ALTER TABLE public.personas ADD COLUMN IF NOT EXISTS description TEXT;

ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;

-- RLS policies (idempotent via DROP IF EXISTS + CREATE)
DROP POLICY IF EXISTS "Users can view their own personas" ON public.personas;
CREATE POLICY "Users can view their own personas"
ON public.personas FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view public personas" ON public.personas;
CREATE POLICY "Users can view public personas"
ON public.personas FOR SELECT
USING (is_public = true);

DROP POLICY IF EXISTS "Users can create their own personas" ON public.personas;
CREATE POLICY "Users can create their own personas"
ON public.personas FOR INSERT
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own personas" ON public.personas;
CREATE POLICY "Users can update their own personas"
ON public.personas FOR UPDATE
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own personas" ON public.personas;
CREATE POLICY "Users can delete their own personas"
ON public.personas FOR DELETE
USING (auth.uid() = user_id);

-- Trigger for updated_at
DROP TRIGGER IF EXISTS update_personas_updated_at ON public.personas;
CREATE TRIGGER update_personas_updated_at
BEFORE UPDATE ON public.personas
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Storage bucket for avatars
INSERT INTO storage.buckets (id, name, public) 
VALUES ('personas', 'personas', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Persona avatars are publicly accessible' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "Persona avatars are publicly accessible"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'personas');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can upload their own persona avatars' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "Users can upload their own persona avatars"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can update their own persona avatars' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "Users can update their own persona avatars"
    ON storage.objects FOR UPDATE
    USING (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'Users can delete their own persona avatars' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "Users can delete their own persona avatars"
    ON storage.objects FOR DELETE
    USING (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);
  END IF;
END $$;

-- Add suno_audio_id column to tracks table
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS suno_audio_id TEXT;
CREATE INDEX IF NOT EXISTS idx_tracks_suno_audio_id ON public.tracks(suno_audio_id);
