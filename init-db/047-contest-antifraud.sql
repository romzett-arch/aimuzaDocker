-- D4: Антифрод конкурсов
ALTER TABLE public.contest_entries ADD COLUMN IF NOT EXISTS fraud_flags jsonb;

INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('contest_antifraud', '{"enabled": true}'::jsonb, 'D4: AI-антифрод голосования в конкурсах')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;
