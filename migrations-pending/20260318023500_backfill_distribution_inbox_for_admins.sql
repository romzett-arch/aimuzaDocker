-- Совместимый backfill: выдать distribution_inbox всем текущим admin/super_admin
INSERT INTO public.moderator_permissions (user_id, category_id, granted_by)
SELECT
  ur.user_id,
  pc.id,
  NULL
FROM public.user_roles ur
JOIN public.permission_categories pc
  ON pc.key = 'distribution_inbox'
WHERE ur.role IN ('admin', 'super_admin')
  AND NOT EXISTS (
    SELECT 1
    FROM public.moderator_permissions mp
    WHERE mp.user_id = ur.user_id
      AND mp.category_id = pc.id
  );
