-- Realtime: публикация weighted_votes для live voting feed (postgres_changes INSERT)
-- Без этого подписка на weighted_votes будет молчать

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'weighted_votes'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.weighted_votes;
  END IF;
EXCEPTION
  WHEN undefined_object THEN NULL; -- publication может не существовать в локальной среде
END $$;
