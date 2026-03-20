-- Страховочный backfill: довыдать distribution_inbox всем текущим admin/super_admin
INSERT INTO public.moderator_permissions (user_id, category_id, granted_by)
SELECT
  ur.user_id,
  pc.id,
  NULL
FROM public.user_roles ur
JOIN public.permission_categories pc
  ON pc.key = 'distribution_inbox'
LEFT JOIN public.moderator_permissions mp
  ON mp.user_id = ur.user_id
 AND mp.category_id = pc.id
WHERE ur.role IN ('admin', 'super_admin')
  AND mp.id IS NULL;
