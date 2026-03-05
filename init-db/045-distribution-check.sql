-- B7: AI-проверка метаданных перед дистрибуцией
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('distribution_check', '{"enabled": true}'::jsonb, 'B7: AI-валидация метаданных для стриминговых площадок (Spotify, Apple Music)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
