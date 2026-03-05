-- Продолжение radio_v3: anon + get_radio_smart_queue + get_radio_stats

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END
$$;

DO $$ BEGIN GRANT EXECUTE ON FUNCTION public.get_radio_listeners(INTEGER) TO anon; EXCEPTION WHEN OTHERS THEN NULL; END $$;
