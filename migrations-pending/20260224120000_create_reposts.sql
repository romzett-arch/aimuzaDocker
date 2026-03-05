-- Reposts table: users can repost tracks to their feed
CREATE TABLE IF NOT EXISTS public.reposts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),

  UNIQUE (user_id, track_id)
);

CREATE INDEX IF NOT EXISTS idx_reposts_user ON public.reposts(user_id);
CREATE INDEX IF NOT EXISTS idx_reposts_track ON public.reposts(track_id);

ALTER TABLE public.reposts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view all reposts"
  ON public.reposts FOR SELECT
  USING (true);

CREATE POLICY "Users can insert own reposts"
  ON public.reposts FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own reposts"
  ON public.reposts FOR DELETE
  USING (auth.uid() = user_id);
