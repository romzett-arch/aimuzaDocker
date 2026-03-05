-- B3/B4: AI поддержки — категоризация и шаблоны ответов
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('support_ai', '{
    "auto_categorize": true,
    "auto_priority": true,
    "suggest_replies": true
  }'::jsonb, 'B3/B4: AI-категоризация тикетов и шаблоны ответов (DeepSeek)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
