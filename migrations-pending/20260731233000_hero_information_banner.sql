BEGIN;

INSERT INTO public.ad_settings(key, value, description)
VALUES (
  'hero_info_banner_config',
  '{"enabled":false,"eyebrow":"Важно","title":"","subtitle":"","cta":"Подробнее","link":"/"}',
  'Информационный слайд Hero Banner на главной странице'
)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_public_ad_settings()
RETURNS TABLE(key TEXT, value TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.key, s.value
  FROM public.ad_settings s
  WHERE s.key IN (
    'ads_enabled', 'ad_free_price', 'ad_free_duration_days',
    'premium_no_ads', 'max_ads_per_session', 'max_ads_per_hour',
    'ad_cooldown_seconds', 'ad_timezone', 'hero_banner_enabled',
    'hero_info_banner_config'
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_public_ad_settings() TO anon, authenticated;

COMMIT;
