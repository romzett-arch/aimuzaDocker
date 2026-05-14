CREATE TABLE IF NOT EXISTS public.release_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'processing',
  zip_url TEXT,
  mp3_url TEXT,
  wav_url TEXT,
  cover_url TEXT,
  genre_txt_url TEXT,
  certificate_url TEXT,
  certificate_pdf_url TEXT,
  blockchain_proof_url TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT release_packages_status_check CHECK (status IN ('processing', 'completed', 'failed'))
);

CREATE UNIQUE INDEX IF NOT EXISTS release_packages_track_id_key
  ON public.release_packages(track_id);

CREATE INDEX IF NOT EXISTS release_packages_user_id_idx
  ON public.release_packages(user_id);

ALTER TABLE public.release_packages ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.release_packages TO authenticated;
GRANT ALL ON public.release_packages TO service_role;

DROP POLICY IF EXISTS "Users can view own release packages" ON public.release_packages;
CREATE POLICY "Users can view own release packages"
  ON public.release_packages
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);
