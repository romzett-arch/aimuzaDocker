-- Table for caching uploaded audio references (Suno uploadUrl valid 3 days)
CREATE TABLE public.user_audio_references (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  upload_url TEXT NOT NULL,
  file_name TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '3 days')
);

CREATE INDEX idx_user_audio_refs_user_expires
  ON public.user_audio_references(user_id, expires_at DESC);

ALTER TABLE public.user_audio_references ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own audio references"
  ON public.user_audio_references FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Service role can insert audio references"
  ON public.user_audio_references FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Users can delete own audio references"
  ON public.user_audio_references FOR DELETE
  USING (auth.uid() = user_id);
