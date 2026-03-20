-- Точечный доступ к модалке модерации дистрибуции
INSERT INTO public.permission_categories (
  key,
  name,
  name_ru,
  description,
  icon,
  sort_order,
  is_active
)
VALUES (
  'distribution_inbox',
  'Distribution Inbox',
  'Модалка дистрибуции',
  'Доступ к полноэкранной модалке модерации дистрибуции вне админки',
  'send',
  210,
  true
)
ON CONFLICT (key) DO UPDATE
SET
  name = EXCLUDED.name,
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  sort_order = EXCLUDED.sort_order,
  is_active = EXCLUDED.is_active;
