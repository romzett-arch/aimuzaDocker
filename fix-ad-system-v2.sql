-- =====================================================
-- Ad System v2: Полная миграция реальной схемы под фронтенд
-- =====================================================
-- Реальная БД имеет упрощённую схему. Фронтенд ожидает расширенную.
-- Этот скрипт дополняет таблицы недостающими колонками и пересоздаёт RPC.

BEGIN;

-- =====================================================
-- 1. ad_campaigns — добавляем недостающие колонки
-- =====================================================
ALTER TABLE public.ad_campaigns
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS advertiser_name text,
  ADD COLUMN IF NOT EXISTS advertiser_url text,
  ADD COLUMN IF NOT EXISTS campaign_type text DEFAULT 'external',
  ADD COLUMN IF NOT EXISTS internal_type text,
  ADD COLUMN IF NOT EXISTS internal_id uuid,
  ADD COLUMN IF NOT EXISTS budget_daily integer,
  ADD COLUMN IF NOT EXISTS budget_total integer,
  ADD COLUMN IF NOT EXISTS impressions_count integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS clicks_count integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS priority integer DEFAULT 50,
  ADD COLUMN IF NOT EXISTS created_by uuid;

-- Перенести данные из старых колонок если есть
UPDATE public.ad_campaigns SET impressions_count = impressions WHERE impressions_count = 0 AND impressions > 0;
UPDATE public.ad_campaigns SET clicks_count = clicks WHERE clicks_count = 0 AND clicks > 0;
UPDATE public.ad_campaigns SET budget_total = budget::integer WHERE budget_total IS NULL AND budget > 0;

-- =====================================================
-- 2. ad_creatives — добавляем недостающие колонки
-- =====================================================
ALTER TABLE public.ad_creatives
  ADD COLUMN IF NOT EXISTS creative_type text DEFAULT 'image',
  ADD COLUMN IF NOT EXISTS subtitle text,
  ADD COLUMN IF NOT EXISTS media_type text,
  ADD COLUMN IF NOT EXISTS thumbnail_url text,
  ADD COLUMN IF NOT EXISTS external_video_url text,
  ADD COLUMN IF NOT EXISTS variant text DEFAULT 'default',
  ADD COLUMN IF NOT EXISTS width integer,
  ADD COLUMN IF NOT EXISTS height integer,
  ADD COLUMN IF NOT EXISTS aspect_ratio text;

-- Перенести type → creative_type
UPDATE public.ad_creatives SET creative_type = type WHERE type IS NOT NULL AND creative_type = 'image' AND type != 'image';
-- Перенести description → subtitle
UPDATE public.ad_creatives SET subtitle = description WHERE subtitle IS NULL AND description IS NOT NULL;

-- =====================================================
-- 3. ad_impressions — добавляем недостающие колонки
-- =====================================================
ALTER TABLE public.ad_impressions
  ADD COLUMN IF NOT EXISTS device_type text,
  ADD COLUMN IF NOT EXISTS page_url text,
  ADD COLUMN IF NOT EXISTS viewed_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS view_duration_ms integer,
  ADD COLUMN IF NOT EXISTS clicked_at timestamptz,
  ADD COLUMN IF NOT EXISTS session_id text;

-- Перенести created_at → viewed_at для существующих записей
UPDATE public.ad_impressions SET viewed_at = created_at WHERE viewed_at IS NULL;
-- Перенести is_click → clicked_at
UPDATE public.ad_impressions SET clicked_at = created_at WHERE is_click = true AND clicked_at IS NULL;

-- =====================================================
-- 4. ad_slots — добавляем недостающие колонки
-- =====================================================
ALTER TABLE public.ad_slots
  ADD COLUMN IF NOT EXISTS slot_key text,
  ADD COLUMN IF NOT EXISTS is_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS max_ads integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS recommended_width integer,
  ADD COLUMN IF NOT EXISTS recommended_height integer,
  ADD COLUMN IF NOT EXISTS recommended_aspect_ratio text,
  ADD COLUMN IF NOT EXISTS supported_types text[],
  ADD COLUMN IF NOT EXISTS frequency_cap integer DEFAULT 10,
  ADD COLUMN IF NOT EXISTS cooldown_seconds integer DEFAULT 60,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Перенести slot_type → slot_key
UPDATE public.ad_slots SET slot_key = slot_type WHERE slot_key IS NULL AND slot_type IS NOT NULL;
UPDATE public.ad_slots SET is_enabled = is_active WHERE is_enabled IS NULL;
UPDATE public.ad_slots SET recommended_width = width WHERE recommended_width IS NULL AND width IS NOT NULL;
UPDATE public.ad_slots SET recommended_height = height WHERE recommended_height IS NULL AND height IS NOT NULL;

-- Создать уникальный индекс на slot_key если нет
CREATE UNIQUE INDEX IF NOT EXISTS ad_slots_slot_key_idx ON public.ad_slots (slot_key);

-- =====================================================
-- 5. ad_targeting — добавляем недостающие колонки
-- =====================================================
ALTER TABLE public.ad_targeting
  ADD COLUMN IF NOT EXISTS target_free_users boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS target_subscribed_users boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS target_mobile boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS target_desktop boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS min_generations integer,
  ADD COLUMN IF NOT EXISTS max_generations integer,
  ADD COLUMN IF NOT EXISTS min_days_registered integer,
  ADD COLUMN IF NOT EXISTS show_hours_start integer,
  ADD COLUMN IF NOT EXISTS show_hours_end integer,
  ADD COLUMN IF NOT EXISTS show_days_of_week integer[],
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Добавляем UNIQUE constraint на campaign_id если нет
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ad_targeting_campaign_id_key'
  ) THEN
    ALTER TABLE public.ad_targeting ADD CONSTRAINT ad_targeting_campaign_id_key UNIQUE (campaign_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- =====================================================
-- 6. ad_campaign_slots — добавляем поля
-- =====================================================
ALTER TABLE public.ad_campaign_slots
  ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS priority_override integer;

-- =====================================================
-- 7. Индексы для быстрых запросов
-- =====================================================
CREATE INDEX IF NOT EXISTS idx_ad_impressions_user_viewed
ON public.ad_impressions (user_id, viewed_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_impressions_campaign_viewed
ON public.ad_impressions (campaign_id, viewed_at DESC);

-- =====================================================
-- 8. Пересоздаём get_ad_for_slot
-- =====================================================
DROP FUNCTION IF EXISTS public.get_ad_for_slot(text, uuid);
DROP FUNCTION IF EXISTS public.get_ad_for_slot(text, uuid, text);

CREATE FUNCTION public.get_ad_for_slot(
  p_slot_key text,
  p_user_id uuid DEFAULT NULL,
  p_device_type text DEFAULT 'desktop'
)
RETURNS TABLE(
  campaign_id uuid,
  creative_id uuid,
  campaign_name text,
  campaign_type text,
  creative_type text,
  title text,
  subtitle text,
  cta_text text,
  click_url text,
  media_url text,
  media_type text,
  thumbnail_url text,
  external_video_url text,
  internal_type text,
  internal_id text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_slot_id uuid;
  v_is_ad_free boolean := false;
  v_ads_enabled boolean := true;
  v_max_impressions_per_hour int := 20;
  v_user_impressions_last_hour int := 0;
  v_current_hour int;
  v_current_dow int;
BEGIN
  -- Глобальный переключатель
  SELECT value::boolean INTO v_ads_enabled
  FROM public.ad_settings
  WHERE key = 'ads_enabled';

  IF NOT COALESCE(v_ads_enabled, true) THEN
    RETURN;
  END IF;

  -- Слот существует и включён?
  SELECT id INTO v_slot_id
  FROM public.ad_slots
  WHERE slot_key = p_slot_key AND COALESCE(is_enabled, is_active, true) = true;

  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;

  -- Проверка ad_free
  IF p_user_id IS NOT NULL THEN
    SELECT CASE
      WHEN p.ad_free_until IS NOT NULL AND p.ad_free_until > now()
      THEN true ELSE false
    END INTO v_is_ad_free
    FROM public.profiles p
    WHERE p.user_id = p_user_id;

    IF v_is_ad_free THEN RETURN; END IF;

    -- Premium-подписка
    IF EXISTS (
      SELECT 1 FROM public.ad_settings WHERE key = 'premium_no_ads' AND value = 'true'
    ) THEN
      IF EXISTS (
        SELECT 1 FROM public.user_subscriptions us
        WHERE us.user_id = p_user_id AND us.status = 'active'
          AND (us.end_date IS NULL OR us.end_date > now())
      ) THEN
        RETURN;
      END IF;
    END IF;
  END IF;

  -- Серверный frequency cap
  SELECT COALESCE(value::int, 20) INTO v_max_impressions_per_hour
  FROM public.ad_settings WHERE key = 'max_ads_per_hour';

  IF p_user_id IS NOT NULL THEN
    SELECT count(*) INTO v_user_impressions_last_hour
    FROM public.ad_impressions ai
    WHERE ai.user_id = p_user_id
      AND COALESCE(ai.viewed_at, ai.created_at) > now() - interval '1 hour';

    IF v_user_impressions_last_hour >= v_max_impressions_per_hour THEN
      RETURN;
    END IF;
  END IF;

  -- Текущее время для таргетинга
  v_current_hour := EXTRACT(HOUR FROM now());
  v_current_dow := EXTRACT(ISODOW FROM now())::int;

  -- Основной запрос
  RETURN QUERY
  SELECT
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    COALESCE(c.campaign_type, 'external') as campaign_type,
    COALESCE(cr.creative_type, cr.type, 'image') as creative_type,
    cr.title,
    COALESCE(cr.subtitle, cr.description) as subtitle,
    cr.cta_text,
    COALESCE(cr.click_url, c.link_url) as click_url,
    COALESCE(cr.media_url, c.image_url) as media_url,
    cr.media_type,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id::text as internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id AND t.target_type IS NULL
  WHERE
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND COALESCE(cs.is_active, true) = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    -- Бюджет: общий
    AND (c.budget_total IS NULL OR COALESCE(c.impressions_count, c.impressions, 0) < c.budget_total)
    -- Бюджет: дневной
    AND (
      c.budget_daily IS NULL
      OR (
        SELECT count(*) FROM public.ad_impressions bi
        WHERE bi.campaign_id = c.id
          AND COALESCE(bi.viewed_at, bi.created_at) >= date_trunc('day', now())
      ) < c.budget_daily
    )
    -- Таргетинг: устройство
    AND (
      t.id IS NULL
      OR (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
    )
    -- Таргетинг: часы показа
    AND (
      t.id IS NULL OR t.show_hours_start IS NULL OR t.show_hours_end IS NULL
      OR (
        CASE
          WHEN t.show_hours_start <= t.show_hours_end THEN
            v_current_hour >= t.show_hours_start AND v_current_hour < t.show_hours_end
          ELSE
            v_current_hour >= t.show_hours_start OR v_current_hour < t.show_hours_end
        END
      )
    )
    -- Таргетинг: дни недели
    AND (
      t.id IS NULL OR t.show_days_of_week IS NULL
      OR v_current_dow = ANY(t.show_days_of_week)
    )
    -- Таргетинг: подписка
    AND (
      t.id IS NULL
      OR (COALESCE(t.target_free_users, true) AND COALESCE(t.target_subscribed_users, true))
      OR (
        t.target_free_users AND NOT EXISTS (
          SELECT 1 FROM public.user_subscriptions us
          WHERE us.user_id = p_user_id AND us.status = 'active'
        )
      )
      OR (
        t.target_subscribed_users AND EXISTS (
          SELECT 1 FROM public.user_subscriptions us
          WHERE us.user_id = p_user_id AND us.status = 'active'
        )
      )
    )
    -- Таргетинг: мин. генераций
    AND (
      t.id IS NULL OR t.min_generations IS NULL OR p_user_id IS NULL
      OR (SELECT count(*) FROM public.tracks tr WHERE tr.user_id = p_user_id) >= t.min_generations
    )
    -- Таргетинг: мин. дней с регистрации
    AND (
      t.id IS NULL OR t.min_days_registered IS NULL OR p_user_id IS NULL
      OR (
        SELECT EXTRACT(DAY FROM now() - p.created_at)
        FROM public.profiles p WHERE p.user_id = p_user_id
      ) >= t.min_days_registered
    )
  ORDER BY
    COALESCE(cs.priority_override, cs.priority, c.priority, 50) DESC,
    random()
  LIMIT 1;
END;
$$;

-- =====================================================
-- 9. Пересоздаём record_ad_impression (расширенная)
-- =====================================================
DROP FUNCTION IF EXISTS public.record_ad_impression(uuid, uuid, uuid, uuid);

CREATE FUNCTION public.record_ad_impression(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_slot_key text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_device_type text DEFAULT 'desktop',
  p_page_url text DEFAULT NULL,
  p_session_id text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_slot_id uuid;
  v_impression_id uuid;
BEGIN
  -- Найти slot_id по ключу (если передан)
  IF p_slot_key IS NOT NULL THEN
    SELECT id INTO v_slot_id FROM public.ad_slots WHERE slot_key = p_slot_key LIMIT 1;
  END IF;

  INSERT INTO public.ad_impressions (
    campaign_id, creative_id, slot_id, user_id,
    device_type, page_url, viewed_at, session_id
  ) VALUES (
    p_campaign_id, p_creative_id, v_slot_id, p_user_id,
    p_device_type, p_page_url, now(), p_session_id
  )
  RETURNING id INTO v_impression_id;

  -- Обновить счётчик кампании
  UPDATE public.ad_campaigns
  SET impressions_count = COALESCE(impressions_count, 0) + 1,
      impressions = COALESCE(impressions, 0) + 1
  WHERE id = p_campaign_id;

  RETURN v_impression_id;
END;
$$;

-- =====================================================
-- 10. Пересоздаём record_ad_click
-- =====================================================
DROP FUNCTION IF EXISTS public.record_ad_click(uuid, uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.record_ad_click(uuid);

CREATE FUNCTION public.record_ad_click(
  p_impression_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_campaign_id uuid;
BEGIN
  -- Обновить impression
  UPDATE public.ad_impressions
  SET clicked_at = now(), is_click = true
  WHERE id = p_impression_id
  RETURNING campaign_id INTO v_campaign_id;

  -- Обновить счётчик кампании
  IF v_campaign_id IS NOT NULL THEN
    UPDATE public.ad_campaigns
    SET clicks_count = COALESCE(clicks_count, 0) + 1,
        clicks = COALESCE(clicks, 0) + 1
    WHERE id = v_campaign_id;
  END IF;
END;
$$;

-- =====================================================
-- 11. Настройка max_ads_per_hour
-- =====================================================
INSERT INTO public.ad_settings (key, value, description)
VALUES ('max_ads_per_hour', '20', 'Макс. показов рекламы пользователю за час (серверная проверка)')
ON CONFLICT (key) DO NOTHING;

-- =====================================================
-- 12. Стандартные слоты если их нет
-- =====================================================
INSERT INTO public.ad_slots (name, slot_type, slot_key, description, is_enabled, is_active)
VALUES
  ('Баннер ленты', 'feed_banner', 'feed_banner', 'Баннер в ленте треков', true, true),
  ('Баннер сайдбара', 'sidebar_banner', 'sidebar_banner', 'Баннер в боковой панели', true, true),
  ('Hero баннер', 'hero_banner', 'hero_banner', 'Главный баннер на главной', true, true),
  ('Между генерациями', 'between_generations', 'between_generations', 'Полноэкранная реклама после генерации', true, true),
  ('Баннер форума (лента)', 'forum_feed', 'forum_feed', 'Баннер в ленте форума', true, true),
  ('Баннер форума (сайдбар)', 'forum_sidebar', 'forum_sidebar', 'Баннер в сайдбаре форума', true, true)
ON CONFLICT DO NOTHING;

COMMIT;
