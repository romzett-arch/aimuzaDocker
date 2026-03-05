-- D2 Уровень 1: AI-интерпретация метрик analyze-audio (DeepSeek)
-- Колонка для хранения текстовых рекомендаций от DeepSeek
ALTER TABLE public.track_health_reports ADD COLUMN IF NOT EXISTS ai_interpretation text;

-- Настройки AI-интерпретации (вкл/выкл, addon для биллинга)
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('audio_interpretation', '{
    "enabled": true,
    "addon_service": "audio_interpretation",
    "price_rub": 5
  }'::jsonb, 'D2: DeepSeek интерпретация метрик analyze-audio (5 ₽)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
