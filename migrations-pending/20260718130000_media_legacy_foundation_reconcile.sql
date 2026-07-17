-- Reconcile legacy media tables required by the video gallery and personas FK.

CREATE TABLE IF NOT EXISTS public.track_addons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL,
  addon_service_id uuid NOT NULL,
  user_id uuid,
  status text NOT NULL DEFAULT 'pending',
  result_url text,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_track_addons_track_id ON public.track_addons(track_id);
CREATE INDEX IF NOT EXISTS idx_track_addons_service_id ON public.track_addons(addon_service_id);

DROP TRIGGER IF EXISTS update_track_addons_updated_at ON public.track_addons;
CREATE TRIGGER update_track_addons_updated_at
BEFORE UPDATE ON public.track_addons
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE IF NOT EXISTS public.personas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  name text NOT NULL,
  avatar_url text,
  source_track_id uuid,
  clip_start_time numeric NOT NULL DEFAULT 0,
  clip_end_time numeric NOT NULL DEFAULT 30,
  suno_persona_id text,
  status text NOT NULL DEFAULT 'pending',
  is_public boolean DEFAULT false,
  description text,
  style_tags text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view their own personas" ON public.personas;
CREATE POLICY "Users can view their own personas" ON public.personas FOR SELECT
USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can view public personas" ON public.personas;
CREATE POLICY "Users can view public personas" ON public.personas FOR SELECT
USING (is_public = true);
DROP POLICY IF EXISTS "Users can create their own personas" ON public.personas;
CREATE POLICY "Users can create their own personas" ON public.personas FOR INSERT
WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can update their own personas" ON public.personas;
CREATE POLICY "Users can update their own personas" ON public.personas FOR UPDATE
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can delete their own personas" ON public.personas;
CREATE POLICY "Users can delete their own personas" ON public.personas FOR DELETE
USING (auth.uid() = user_id);

DROP TRIGGER IF EXISTS update_personas_updated_at ON public.personas;
CREATE TRIGGER update_personas_updated_at
BEFORE UPDATE ON public.personas
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

GRANT SELECT, INSERT, UPDATE, DELETE ON public.track_addons, public.personas TO authenticated;
GRANT ALL ON public.track_addons, public.personas TO service_role;
