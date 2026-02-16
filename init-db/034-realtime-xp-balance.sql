-- ═══════════════════════════════════════════════════════════════
-- 034-realtime-xp-balance.sql
-- Realtime для XP и баланса: обновление цифр в моменте
-- ═══════════════════════════════════════════════════════════════

-- 1. Добавить таблицы в публикацию realtime
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'forum_user_stats'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_user_stats;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'profiles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 2. REPLICA IDENTITY FULL — чтобы фильтр по user_id работал в realtime
-- (по умолчанию в событие попадает только PK; для фильтра user_id нужны все колонки)
ALTER TABLE public.forum_user_stats REPLICA IDENTITY FULL;
ALTER TABLE public.profiles REPLICA IDENTITY FULL;
