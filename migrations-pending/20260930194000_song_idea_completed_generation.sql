-- A song idea counts as used only when one of its generated tracks reaches completed.

CREATE TABLE IF NOT EXISTS public.song_idea_generation_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  discovery_id UUID NOT NULL REFERENCES public.song_idea_discoveries(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (track_id)
);

CREATE INDEX IF NOT EXISTS idx_song_idea_generation_attempts_discovery
  ON public.song_idea_generation_attempts (discovery_id);

ALTER TABLE public.song_idea_generation_attempts ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.record_song_idea_generation(
  p_idea_id UUID,
  p_track_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_discovery_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  SELECT id INTO v_discovery_id
  FROM public.song_idea_discoveries
  WHERE user_id = auth.uid()
    AND idea_id = p_idea_id
    AND accepted_at IS NOT NULL;

  IF v_discovery_id IS NULL THEN
    RAISE EXCEPTION 'Идея не принята текущим пользователем';
  END IF;

  INSERT INTO public.song_idea_generation_attempts (discovery_id, track_id)
  SELECT v_discovery_id, input_track.id
  FROM unnest(COALESCE(p_track_ids, ARRAY[]::UUID[])) AS input_track(id)
  JOIN public.tracks t ON t.id = input_track.id AND t.user_id = auth.uid()
  ON CONFLICT (track_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_song_idea_on_completed_track()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    UPDATE public.song_idea_discoveries d
    SET used_at = COALESCE(d.used_at, now())
    FROM public.song_idea_generation_attempts a
    WHERE a.track_id = NEW.id
      AND a.discovery_id = d.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_song_idea_completed_track ON public.tracks;
CREATE TRIGGER trg_song_idea_completed_track
AFTER UPDATE OF status ON public.tracks
FOR EACH ROW EXECUTE FUNCTION public.mark_song_idea_on_completed_track();

GRANT EXECUTE ON FUNCTION public.record_song_idea_generation(UUID, UUID[]) TO authenticated;
