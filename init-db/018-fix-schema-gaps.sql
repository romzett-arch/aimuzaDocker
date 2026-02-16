-- ═══════════════════════════════════════════════════════════════
-- 018-fix-schema-gaps.sql
-- Добавляет колонки и таблицы, которые фронтенд ожидает,
-- но которых нет в init-db SQL.
-- Безопасно для повторного применения (IF NOT EXISTS / IF NOT EXISTS).
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. track_comments: поля для цитирования и таймстемпов ───

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema='public' AND table_name='track_comments' AND column_name='timestamp_seconds'
  ) THEN
    ALTER TABLE public.track_comments ADD COLUMN timestamp_seconds INTEGER;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema='public' AND table_name='track_comments' AND column_name='quote_text'
  ) THEN
    ALTER TABLE public.track_comments ADD COLUMN quote_text TEXT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema='public' AND table_name='track_comments' AND column_name='quote_author'
  ) THEN
    ALTER TABLE public.track_comments ADD COLUMN quote_author TEXT;
  END IF;
END $$;

-- ─── 2. profiles: колонка credits для форумной экономики ──────

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema='public' AND table_name='profiles' AND column_name='credits'
  ) THEN
    ALTER TABLE public.profiles ADD COLUMN credits INTEGER DEFAULT 0;
  END IF;
END $$;

-- ─── 3. track_reactions: реакции-эмодзи на треки ─────────────

CREATE TABLE IF NOT EXISTS public.track_reactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reaction_type TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(track_id, user_id, reaction_type)
);

CREATE INDEX IF NOT EXISTS idx_track_reactions_track ON public.track_reactions(track_id);
CREATE INDEX IF NOT EXISTS idx_track_reactions_user ON public.track_reactions(user_id);

ALTER TABLE public.track_reactions ENABLE ROW LEVEL SECURITY;

-- RLS: все видят реакции, авторизованные могут добавлять/удалять свои
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='track_reactions' AND policyname='track_reactions_select') THEN
    CREATE POLICY track_reactions_select ON public.track_reactions FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='track_reactions' AND policyname='track_reactions_insert') THEN
    CREATE POLICY track_reactions_insert ON public.track_reactions FOR INSERT WITH CHECK (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='track_reactions' AND policyname='track_reactions_delete') THEN
    CREATE POLICY track_reactions_delete ON public.track_reactions FOR DELETE USING (auth.uid() = user_id);
  END IF;
END $$;
