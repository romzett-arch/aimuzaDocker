-- D2 Уровень 2: RoEx Tonn API про-анализ микса
ALTER TABLE public.track_health_reports ADD COLUMN IF NOT EXISTS mix_pro_result jsonb;

INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('mix_quality', '{"enabled": true, "price_rub": 10}'::jsonb, 'D2: RoEx Tonn API про-анализ микса (mix_pro_analysis, 10 ₽)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
