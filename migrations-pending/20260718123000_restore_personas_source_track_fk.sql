-- Keep the local and production schemas aligned so schema-only restores know
-- that personas.source_track_id depends on tracks(id).

DO $$
BEGIN
  IF to_regclass('public.personas') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM pg_constraint
       WHERE conrelid = 'public.personas'::regclass
         AND conname = 'personas_source_track_id_fkey'
     ) THEN
    UPDATE public.personas AS persona
    SET source_track_id = NULL
    WHERE source_track_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.tracks AS track
        WHERE track.id = persona.source_track_id
      );

    ALTER TABLE public.personas
      ADD CONSTRAINT personas_source_track_id_fkey
      FOREIGN KEY (source_track_id)
      REFERENCES public.tracks(id)
      ON DELETE SET NULL;
  END IF;
END
$$;
