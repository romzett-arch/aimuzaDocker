-- Clarify the shared catalog used by the website and Studio; quotas/prices stay unchanged.
WITH clarified AS (
  SELECT p.id,
    jsonb_agg(
      CASE
        WHEN f.text ~ '^[0-9]+ трек(ов)?/месяц бесплатно$' THEN
          'Загрузки треков: ' || split_part(f.text, ' ', 1) || ' в месяц включено'
        WHEN f.text ~ '^Сверх лимита — .*₽/трек$' THEN
          replace(replace(f.text, 'Сверх лимита — ', 'Дополнительные загрузки — '), '₽/трек', '₽ за трек')
        ELSE f.text
      END ORDER BY f.position
    ) AS features
  FROM public.subscription_plans p
  CROSS JOIN LATERAL jsonb_array_elements_text(p.features) WITH ORDINALITY AS f(text, position)
  WHERE jsonb_typeof(p.features) = 'array'
  GROUP BY p.id
)
UPDATE public.subscription_plans p
SET features = CASE
      WHEN c.features @> '["Генерация музыки оплачивается отдельно"]'::jsonb THEN c.features
      ELSE c.features || '["Генерация музыки оплачивается отдельно"]'::jsonb
    END,
    updated_at = now()
FROM clarified c
WHERE p.id = c.id
  AND p.features IS DISTINCT FROM CASE
    WHEN c.features @> '["Генерация музыки оплачивается отдельно"]'::jsonb THEN c.features
    ELSE c.features || '["Генерация музыки оплачивается отдельно"]'::jsonb
  END;
