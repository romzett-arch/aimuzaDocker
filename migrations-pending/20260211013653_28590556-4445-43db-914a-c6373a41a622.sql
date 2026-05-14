-- Add forum ad slots
INSERT INTO ad_slots (slot_key, name, description, is_enabled, max_ads, recommended_width, recommended_height, recommended_aspect_ratio, supported_types, frequency_cap, cooldown_seconds)
VALUES 
  ('forum_sidebar', 'Форум: боковая панель', 'Рекламный баннер в боковой панели форума (под виджетами)', true, 1, 280, 200, '7:5', ARRAY['image'], 3, 300),
  ('forum_feed', 'Форум: между темами', 'Нативная рекламная карточка среди списка тем форума', true, 1, 600, 200, '3:1', ARRAY['image', 'video'], 5, 600)
ON CONFLICT (slot_key) DO NOTHING;