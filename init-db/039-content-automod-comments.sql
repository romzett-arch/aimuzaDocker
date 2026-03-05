-- A1: Модерация комментариев — настройки content_automod для forum-automod
-- Позволяет включать/выключать AI-модерацию комментариев к трекам
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('content_automod', '{
    "comments_enabled": true,
    "comments_toxicity": true,
    "comments_spam": true,
    "comments_confidence_threshold": 0.7,
    "comments_min_text_length": 10,
    "messages_enabled": true,
    "messages_spam": true,
    "messages_phishing": true,
    "messages_confidence_threshold": 0.8,
    "messages_skip_trust_level": 2
  }'::jsonb, 'Настройки AI-модерации контента: комментарии к трекам, личные сообщения')
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description;
