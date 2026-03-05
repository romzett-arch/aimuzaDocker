-- ═══════════════════════════════════════════════════════════════
-- D3 Фаза 2: pgvector + audio_embedding (при каталоге > 50K)
-- Инфраструктура для поиска похожих треков по эмбеддингам
-- ═══════════════════════════════════════════════════════════════

-- 1. Расширение pgvector (Supabase поддерживает)
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Колонка audio_embedding в tracks (512 dim — CLAP/LAION)
ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS audio_embedding vector(512);

-- 3. Индекс IVFFlat — создавать вручную при наличии эмбеддингов:
--    CREATE INDEX idx_tracks_audio_embedding ON tracks
--    USING ivfflat (audio_embedding vector_cosine_ops) WITH (lists = 100)
--    WHERE audio_embedding IS NOT NULL;

-- 4. Обновление similar_tracks: method = metadata | embeddings
UPDATE public.forum_automod_settings
SET value = jsonb_set(
  COALESCE(value, '{}'::jsonb),
  '{method}',
  '"metadata"'
)
WHERE key = 'similar_tracks'
  AND (value->>'method') IS NULL;

-- Добавляем method: embeddings в описание для будущего
UPDATE public.forum_automod_settings
SET description = 'D3: Похожие треки. method: metadata (по умолчанию) | embeddings (при заполненном audio_embedding)'
WHERE key = 'similar_tracks';
