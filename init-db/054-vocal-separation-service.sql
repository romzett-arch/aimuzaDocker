-- Suno Vocal & Instrument Stem Separation: default selling price, editable in admin.
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES (
  'vocal_separation',
  'Разделение вокала',
  'Создаёт отдельные дорожки вокала и инструментала через Suno API',
  10,
  'mic',
  TRUE,
  4
)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = 10,
  is_active = TRUE;
