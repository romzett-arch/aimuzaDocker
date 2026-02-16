-- =====================================================
-- Диагностика и исправление таблицы tracks
-- Запустить: docker exec -i aimuza-db psql -U aimuza aimuza < fix-all-tracks-columns.sql
-- =====================================================

-- 1. Показать текущие колонки
DO $$
BEGIN
  RAISE NOTICE '=== Текущие колонки таблицы tracks ===';
END $$;

SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'tracks'
ORDER BY ordinal_position;

-- 2. Добавить все потенциально отсутствующие колонки
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS error_message text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS position integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS source_type text DEFAULT 'generated';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_status text DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_rejection_reason text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_notes text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_status text DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_result jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_checked_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_status text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_submitted_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_rejection_reason text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_platforms jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_requested_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_approved_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_approved_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS is_original_work boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_samples boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS samples_licensed boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_interpolations boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS interpolations_licensed boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS performer_name text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS label_name text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS music_author text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS lyrics_author text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS isrc_code text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS prompt_text text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS tags text[];
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS bpm integer;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS key_signature text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS suno_id text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS suno_audio_id text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS video_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS is_boosted boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS boost_expires_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS downloads_count integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS shares_count integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS share_token text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS wav_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS master_audio_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS master_uploaded_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS certificate_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS contest_winner_badge jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_started_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_ends_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_likes_count integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_dislikes_count integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_result text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_type text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS audio_reference_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS plagiarism_check_status text DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS plagiarism_check_result jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_stage text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_progress integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_started_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS upscale_detected boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS lufs_normalized boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS metadata_cleaned boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS blockchain_hash text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS gold_pack_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS forum_topic_id uuid;

-- 3. Индексы
CREATE INDEX IF NOT EXISTS idx_tracks_position ON public.tracks(user_id, position);
CREATE INDEX IF NOT EXISTS idx_tracks_suno_audio_id ON public.tracks(suno_audio_id);

-- 4. Диагностика: показать все треки с ключевыми полями
DO $$
BEGIN
  RAISE NOTICE '=== Диагностика треков ===';
END $$;

SELECT id, title, status, audio_url IS NOT NULL as has_audio, 
       cover_url IS NOT NULL as has_cover, duration, position,
       genre_id IS NOT NULL as has_genre, created_at
FROM public.tracks
ORDER BY created_at DESC
LIMIT 20;

-- 5. Показать количество треков по статусам
SELECT status, count(*) as cnt FROM public.tracks GROUP BY status ORDER BY cnt DESC;
