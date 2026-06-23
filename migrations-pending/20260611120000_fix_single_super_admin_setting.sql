-- Keep the protected super_admin setting aligned when the database has one super_admin.
WITH super_admin_count AS (
  SELECT count(*) AS total
  FROM public.user_roles
  WHERE role = 'super_admin'
),
single_super_admin AS (
  SELECT user_id
  FROM public.user_roles
  WHERE role = 'super_admin'
    AND (SELECT total FROM super_admin_count) = 1
  LIMIT 1
)
INSERT INTO public.settings (key, value, description)
SELECT
  'super_admin_id',
  user_id::text,
  'ID главного администратора (защищённый)'
FROM single_super_admin
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description
WHERE public.settings.value IS DISTINCT FROM EXCLUDED.value;
