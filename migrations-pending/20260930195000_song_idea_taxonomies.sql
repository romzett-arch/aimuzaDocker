-- Admin-managed vocabulary for song idea cards and search suggestions.

CREATE TABLE IF NOT EXISTS public.song_idea_taxonomy_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind TEXT NOT NULL CHECK (kind IN ('genre', 'mood', 'energy', 'theme')),
  value TEXT NOT NULL CHECK (char_length(trim(value)) BETWEEN 1 AND 80),
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kind, value)
);

CREATE INDEX IF NOT EXISTS idx_song_idea_taxonomy_options_active
  ON public.song_idea_taxonomy_options (kind, is_active, sort_order, value);

ALTER TABLE public.song_idea_taxonomy_options ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Active song idea taxonomy is readable" ON public.song_idea_taxonomy_options;
CREATE POLICY "Active song idea taxonomy is readable" ON public.song_idea_taxonomy_options
  FOR SELECT USING (is_active OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins manage song idea taxonomy" ON public.song_idea_taxonomy_options;
CREATE POLICY "Admins manage song idea taxonomy" ON public.song_idea_taxonomy_options
  FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'genre', trim(value)
FROM public.song_ideas, unnest(genres) AS value
WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;

INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'mood', trim(value)
FROM public.song_ideas, unnest(moods) AS value
WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;

INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'theme', trim(value)
FROM public.song_ideas, unnest(themes) AS value
WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;

INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'energy', trim(energy)
FROM public.song_ideas
WHERE trim(energy) <> ''
ON CONFLICT (kind, value) DO NOTHING;
