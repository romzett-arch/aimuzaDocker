-- ═══════════════════════════════════════════════════════════
-- STEP 1: Add UNIQUE constraint on key if not exists
-- ═══════════════════════════════════════════════════════════
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'permission_categories_key_key'
  ) THEN
    ALTER TABLE public.permission_categories ADD CONSTRAINT permission_categories_key_key UNIQUE (key);
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════
-- STEP 2: Insert 13 permission categories
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.permission_categories (key, name, name_ru, description, icon, sort_order, is_active)
VALUES
  ('users',          'Users',          'Пользователи',      'Управление пользователями, верификация, блокировки',    'Users',         1,  true),
  ('moderation',     'Moderation',     'Модерация',         'Модерация треков, голосование, авторские права',         'Shield',        2,  true),
  ('tracks',         'Tracks',         'Треки',             'Просмотр и управление всеми треками',                   'Music',         3,  true),
  ('forum',          'Forum',          'Форум',             'Модерация форума, баны, варнинги, категории',            'MessageSquare', 4,  true),
  ('support',        'Support',        'Поддержка',         'Тикеты поддержки и баг-репорты',                        'Headset',       5,  true),
  ('events',         'Events',         'Мероприятия',       'Конкурсы и объявления',                                 'Award',         6,  true),
  ('economy',        'Economy',        'Экономика',         'Баланс, XP, реферальная система',                       'DollarSign',    7,  true),
  ('revenue',        'Revenue',        'Монетизация',       'Подписки, реклама, депозиты',                           'TrendingUp',    8,  true),
  ('catalog',        'Catalog',        'Справочники',       'Жанры, стили, модели, шаблоны',                         'Database',      9,  true),
  ('feed',           'Feed',           'Лента',             'Настройка алгоритма умной ленты',                       'Activity',      10, true),
  ('radio',          'Radio',          'Радио',             'Управление радио, аукцион, Listen-to-Earn',             'Radio',         11, true),
  ('communications', 'Communications', 'Коммуникации',      'Email-рассылки и push-уведомления',                     'Send',          12, true),
  ('system',         'System',         'Система',           'Системные настройки, AI, логи, техработы',              'Settings',      13, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  sort_order = EXCLUDED.sort_order,
  is_active = EXCLUDED.is_active;

-- ═══════════════════════════════════════════════════════════
-- STEP 3: Update existing moderator presets with correct category_ids
-- ═══════════════════════════════════════════════════════════
DO $$
DECLARE
  v_content_mod_ids UUID[];
  v_forum_mod_ids UUID[];
  v_full_mod_ids UUID[];
  v_community_ids UUID[];
BEGIN
  SELECT ARRAY_AGG(id ORDER BY sort_order) INTO v_content_mod_ids
  FROM public.permission_categories WHERE key IN ('moderation', 'tracks');

  SELECT ARRAY_AGG(id ORDER BY sort_order) INTO v_forum_mod_ids
  FROM public.permission_categories WHERE key IN ('forum', 'support');

  SELECT ARRAY_AGG(id ORDER BY sort_order) INTO v_full_mod_ids
  FROM public.permission_categories WHERE key IN ('moderation', 'tracks', 'forum', 'support');

  SELECT ARRAY_AGG(id ORDER BY sort_order) INTO v_community_ids
  FROM public.permission_categories WHERE key IN ('forum', 'support', 'events', 'communications');

  -- Update presets with correct category_ids
  UPDATE public.moderator_presets SET category_ids = v_content_mod_ids WHERE name = 'Content Moderator';
  UPDATE public.moderator_presets SET category_ids = v_forum_mod_ids   WHERE name = 'Forum Moderator';
  UPDATE public.moderator_presets SET category_ids = v_full_mod_ids    WHERE name = 'Full Moderator';
  UPDATE public.moderator_presets SET category_ids = v_community_ids   WHERE name = 'Community Manager';
END $$;

-- ═══════════════════════════════════════════════════════════
-- VERIFY
-- ═══════════════════════════════════════════════════════════
SELECT key, name_ru, icon, sort_order FROM public.permission_categories ORDER BY sort_order;
SELECT name, name_ru, array_length(category_ids, 1) as perms_count FROM public.moderator_presets ORDER BY sort_order;
