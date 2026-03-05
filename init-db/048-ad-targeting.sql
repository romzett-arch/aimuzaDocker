-- D5: AI-таргетинг рекламы
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('ad_targeting', '{"enabled": false}'::jsonb, 'D5: AI-подбор рекламы по профилю пользователя (DeepSeek)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
