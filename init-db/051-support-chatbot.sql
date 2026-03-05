-- ═══════════════════════════════════════════════════════════════
-- C4: AI-чатбот поддержки — support_chatbot
-- Первая линия ответов: автоответ на новые тикеты
-- ═══════════════════════════════════════════════════════════════

INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('support_chatbot', '{"enabled": false, "auto_reply": false, "escalate_threshold": 3, "max_auto_replies": 2, "bot_user_id": null}'::jsonb, 'C4: AI-чатбот первой линии. auto_reply — автоответ, bot_user_id — UUID для постинга (null = super_admin_id)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
