-- Paid replacement of a selected section in an existing track.

INSERT INTO public.addon_services (
  name,
  name_ru,
  description,
  description_ru,
  price_rub,
  price_aipci,
  base_cost_credits,
  category,
  icon,
  is_active,
  sort_order,
  provider,
  provider_operation,
  provider_model,
  provider_options
) VALUES (
  'replace_music_section',
  'Заменить фрагмент песни',
  'Regenerate a selected 10+ second section and blend it into the source track',
  'Перегенерация выбранного фрагмента от 10 секунд с автоматической сшивкой',
  35,
  10,
  10,
  'music',
  'Scissors',
  true,
  24,
  'sunoapi',
  'replace_section',
  'V6',
  '{"minimum_interval_seconds":10,"maximum_track_share":0.5,"result_variants":2}'::jsonb
)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  description_ru = EXCLUDED.description_ru,
  category = EXCLUDED.category,
  icon = EXCLUDED.icon,
  provider = EXCLUDED.provider,
  provider_operation = EXCLUDED.provider_operation,
  provider_model = EXCLUDED.provider_model,
  provider_options = EXCLUDED.provider_options,
  base_cost_credits = CASE
    WHEN public.addon_services.base_cost_credits = 0 THEN EXCLUDED.base_cost_credits
    ELSE public.addon_services.base_cost_credits
  END,
  price_aipci = CASE
    WHEN public.addon_services.price_aipci = 0 THEN EXCLUDED.price_aipci
    ELSE public.addon_services.price_aipci
  END,
  price_rub = CASE
    WHEN public.addon_services.price_rub = 0 THEN EXCLUDED.price_rub
    ELSE public.addon_services.price_rub
  END,
  updated_at = now();
