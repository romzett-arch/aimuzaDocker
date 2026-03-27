INSERT INTO public.ai_models (name, version, description, is_hot, is_active, sort_order)
SELECT 'Suno', 'V5.5', 'Новая модель Suno с расширенной настройкой звучания и голоса', true, true, 1
WHERE NOT EXISTS (
  SELECT 1
  FROM public.ai_models
  WHERE name = 'Suno' AND version = 'V5.5'
);

UPDATE public.ai_models
SET sort_order = 2
WHERE name = 'Suno' AND version = 'V5' AND sort_order = 1;
