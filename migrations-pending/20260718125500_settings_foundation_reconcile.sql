-- Reconcile installations that predate the shared application settings table.

CREATE TABLE IF NOT EXISTS public.settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.settings(key, value, description)
VALUES ('voting_duration_days', '7', 'Длительность публичного голосования в днях')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.settings(key, value, description)
SELECT
  'forum_voting_category_id',
  category.id::text,
  'Категория форума для публичных голосований'
FROM public.forum_categories category
WHERE category.slug IN ('voting', 'news')
  AND (
    category.slug = 'voting'
    OR lower(coalesce(category.name, '')) LIKE '%голос%'
    OR lower(coalesce(category.name_ru, '')) LIKE '%голос%'
  )
ORDER BY CASE WHEN category.slug = 'voting' THEN 0 ELSE 1 END, category.created_at
LIMIT 1
ON CONFLICT (key) DO NOTHING;

DROP TRIGGER IF EXISTS update_settings_updated_at ON public.settings;
CREATE TRIGGER update_settings_updated_at
BEFORE UPDATE ON public.settings
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

GRANT ALL ON public.settings TO service_role;
