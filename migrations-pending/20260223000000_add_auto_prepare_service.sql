-- Add unique constraint on name (needed for upsert pattern)
CREATE UNIQUE INDEX IF NOT EXISTS addon_services_name_key ON public.addon_services (name);

-- Add auto_prepare addon service (combined AI prompt + markup in one click)
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES (
  'auto_prepare',
  'AI Промт + теги',
  'ИИ за один клик расставит структурные теги и создаст стиль (жанр, темп, голос, настроение)',
  8,
  'wand-2',
  TRUE,
  15
)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub,
  icon = EXCLUDED.icon,
  is_active = EXCLUDED.is_active;
