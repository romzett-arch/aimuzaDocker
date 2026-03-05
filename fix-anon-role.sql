-- Создать anon если нет (для совместимости с Supabase-миграциями)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END
$$;
GRANT EXECUTE ON FUNCTION public.get_radio_listeners(INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION public.get_radio_stats() TO anon;
