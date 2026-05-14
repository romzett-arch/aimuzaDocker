-- Reposition AIMUZA from "music generator" to social platform for AI musicians.
-- Keeps DB SEO overrides aligned with code fallbacks.

INSERT INTO public.seo_metadata (
  entity_type,
  page_key,
  title,
  description,
  keywords,
  og_title,
  og_description,
  robots_directive,
  ai_generated,
  is_active,
  updated_at
)
VALUES
  (
    'page',
    'home',
    'Социальная сеть AI-музыкантов и релизы через НОТА-ФЕЯ',
    'Публикуйте треки, развивайте профиль артиста, находите слушателей и выпускайте музыку на цифровые площадки через лейбл НОТА-ФЕЯ.',
    ARRAY['AI-музыканты', 'AI-артисты', 'социальная сеть музыкантов', 'публикация треков', 'НОТА-ФЕЯ', 'дистрибуция музыки'],
    'AIMUZA — социальная сеть AI-музыкантов',
    'Публикуйте треки, находите слушателей и выпускайте релизы через музыкальный лейбл НОТА-ФЕЯ.',
    'index, follow',
    false,
    true,
    now()
  ),
  (
    'page',
    'pricing',
    'Тарифы AIMUZA для артистов и релизов',
    'Изучите тарифы AIMUZA для артистов: публикация треков, AI-инструменты, депонирование, продвижение и дистрибуция релизов.',
    ARRAY['тарифы AIMUZA', 'дистрибуция музыки', 'AI-инструменты', 'депонирование треков', 'продвижение треков'],
    'Тарифы AIMUZA для AI-музыкантов',
    'Стоимость инструментов, продвижения, депонирования и релизов через НОТА-ФЕЯ.',
    'index, follow',
    false,
    true,
    now()
  ),
  (
    'page',
    'users',
    'AI-музыканты и артисты AIMUZA',
    'Изучайте профили AI-музыкантов и участников сообщества AIMUZA, находите авторов, слушателей и новые коллаборации.',
    ARRAY['AI-музыканты', 'профили артистов', 'музыкальное сообщество', 'коллаборации'],
    'AI-музыканты и артисты AIMUZA',
    'Профили артистов, треки, подписки и музыкальные коллаборации внутри AIMUZA.',
    'index, follow',
    false,
    true,
    now()
  ),
  (
    'page',
    'forum',
    'Форум AI-музыкантов и артистов',
    'Обсуждайте музыку, AI-инструменты, продакшн, публикацию треков и дистрибуцию на форуме сообщества AIMUZA.',
    ARRAY['форум музыкантов', 'AI-музыканты', 'музыкальный продакшн', 'дистрибуция треков'],
    'Форум сообщества AIMUZA',
    'Обсуждения для AI-музыкантов: релизы, продакшн, инструменты и путь на площадки.',
    'index, follow',
    false,
    true,
    now()
  )
ON CONFLICT (entity_type, page_key) WHERE page_key IS NOT NULL
DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  keywords = EXCLUDED.keywords,
  og_title = EXCLUDED.og_title,
  og_description = EXCLUDED.og_description,
  robots_directive = EXCLUDED.robots_directive,
  ai_generated = EXCLUDED.ai_generated,
  is_active = EXCLUDED.is_active,
  updated_at = now();
