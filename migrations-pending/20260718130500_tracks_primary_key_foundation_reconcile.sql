-- Legacy production had tracks.id populated and unique but lacked its PK.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.tracks'::regclass AND contype = 'p'
  ) THEN
    IF EXISTS (SELECT 1 FROM public.tracks WHERE id IS NULL)
       OR EXISTS (SELECT id FROM public.tracks GROUP BY id HAVING count(*) > 1) THEN
      RAISE EXCEPTION 'Cannot restore tracks primary key: invalid track ids';
    END IF;

    ALTER TABLE public.tracks ADD CONSTRAINT tracks_pkey PRIMARY KEY (id);
  END IF;
END;
$$;
