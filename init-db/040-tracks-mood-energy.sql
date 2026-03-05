-- D1: Поля для AI-классификации аудио (mood, energy, bpm)
-- Используются classify-audio (Replicate MTG) и D3 get_similar_tracks
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS mood text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS energy real;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS ai_classified_at timestamptz;

-- Настройки AI-классификации (вкл/выкл, провайдер)
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('audio_classification', '{
    "enabled": false,
    "provider": "replicate_mtg",
    "auto_classify_uploads": true,
    "auto_classify_generated": false,
    "confidence_threshold": 0.6
  }'::jsonb, 'D1: AI-классификация жанра/настроения из аудио (Replicate MTG)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
