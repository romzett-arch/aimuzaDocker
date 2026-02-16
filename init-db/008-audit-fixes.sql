-- ═══════════════════════════════════════════════════════════════════
-- 008-audit-fixes.sql
-- Исправления из аудита + недостающие колонки tracks
-- ═══════════════════════════════════════════════════════════════════

-- B1/C3: Функция get_user_stats читала из пустой таблицы follows вместо user_follows
CREATE OR REPLACE FUNCTION public.get_user_stats(p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'tracks_count', (SELECT COUNT(*) FROM public.tracks WHERE user_id = p_user_id),
    'total_likes', COALESCE((SELECT SUM(likes_count) FROM public.tracks WHERE user_id = p_user_id), 0),
    'followers_count', (SELECT COUNT(*) FROM public.user_follows WHERE following_id = p_user_id),
    'following_count', (SELECT COUNT(*) FROM public.user_follows WHERE follower_id = p_user_id)
  ) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Недостающие колонки в tracks (для загрузки треков, модерации, copyright)
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_status text DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_result jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_checked_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS plagiarism_check_status text DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS plagiarism_check_result jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS is_original_work boolean DEFAULT true;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_samples boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS samples_licensed boolean;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS performer_name text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS label_name text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS wav_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS master_audio_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS certificate_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS contest_winner_badge jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_rejection_reason text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_notes text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS forum_topic_id uuid;
