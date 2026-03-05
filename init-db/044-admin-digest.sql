-- B5: AI-дайджест для админки
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('admin_digest', '{"enabled": true}'::jsonb, 'B5: AI-дайджест метрик на AdminDashboard')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
