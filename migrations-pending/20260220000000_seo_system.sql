-- ============================================
-- SEO-Завод: seo_metadata, seo_robots_rules, seo_ai_config
-- Slug для tracks и profiles, триггеры, RLS
-- ============================================

-- 1a. Главная таблица seo_metadata
CREATE TABLE public.seo_metadata (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL CHECK (entity_type IN ('track', 'profile', 'forum_topic', 'page', 'contest')),
  entity_id UUID,
  page_key TEXT,

  title TEXT,
  description TEXT,
  keywords TEXT[],
  og_title TEXT,
  og_description TEXT,
  og_image_url TEXT,
  canonical_url TEXT,
  robots_directive TEXT DEFAULT 'index, follow',

  ai_generated BOOLEAN DEFAULT false,
  ai_generated_at TIMESTAMPTZ,
  ai_model TEXT,

  yandex_verification TEXT,

  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id)
);

CREATE UNIQUE INDEX idx_seo_metadata_entity_unique ON seo_metadata(entity_type, entity_id) WHERE entity_id IS NOT NULL;
CREATE UNIQUE INDEX idx_seo_metadata_page_unique ON seo_metadata(entity_type, page_key) WHERE page_key IS NOT NULL;
CREATE INDEX idx_seo_metadata_entity ON seo_metadata(entity_type, entity_id);
CREATE INDEX idx_seo_metadata_page ON seo_metadata(entity_type, page_key);
CREATE INDEX idx_seo_metadata_empty ON seo_metadata(entity_type) WHERE title IS NULL;

-- 1b. Таблица seo_robots_rules
CREATE TABLE public.seo_robots_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_agent TEXT NOT NULL,
  rule_type TEXT NOT NULL CHECK (rule_type IN ('allow', 'disallow')),
  path TEXT NOT NULL,
  crawl_delay INT,
  sort_order INT DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 1c. Таблица seo_ai_config
CREATE TABLE public.seo_ai_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key TEXT NOT NULL UNIQUE,
  config_value TEXT NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO public.seo_ai_config (config_key, config_value, description) VALUES
  ('prompt_template', 'Ты — SEO-копирайтер музыкальной платформы AIMUZA. Пиши на русском языке, с призывом к действию. Оптимизируй под Google и Яндекс.', 'Основной системный промт'),
  ('prompt_style', 'профессионально', 'Стиль: дерзко / профессионально / для молодежи / нейтрально'),
  ('ai_provider', 'deepseek', 'Провайдер: deepseek / openrouter'),
  ('ai_model', 'deepseek-chat', 'Модель AI'),
  ('ai_base_url', 'https://api.deepseek.com/v1', 'Базовый URL API'),
  ('indexnow_key', '', 'IndexNow API Key для Яндекс/Bing')
ON CONFLICT (config_key) DO NOTHING;

-- 1d. Функция транслитерации (кириллица -> латиница)
CREATE OR REPLACE FUNCTION public.transliterate_ru(input TEXT) RETURNS TEXT AS $$
  SELECT translate(lower(coalesce(input, '')),
    'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
    'abvgdeejziiklmnoprstufhcchshshyeyuya'
  );
$$ LANGUAGE sql IMMUTABLE;

-- 1e. Slug для треков
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS slug TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_slug ON public.tracks(slug) WHERE slug IS NOT NULL;

CREATE OR REPLACE FUNCTION public.generate_track_slug() RETURNS TRIGGER AS $$
DECLARE
  base_slug TEXT;
  artist TEXT;
  final_slug TEXT;
  counter INT := 0;
BEGIN
  IF NEW.slug IS NOT NULL AND NEW.slug != '' THEN RETURN NEW; END IF;
  SELECT username INTO artist FROM public.profiles WHERE user_id = NEW.user_id LIMIT 1;
  base_slug := lower(regexp_replace(
    public.transliterate_ru(coalesce(NEW.title, 'track')),
    '[^a-z0-9]+', '-', 'g'
  ));
  base_slug := trim(both '-' from base_slug);
  IF base_slug = '' THEN base_slug := 'track'; END IF;
  IF artist IS NOT NULL AND artist != '' THEN
    base_slug := base_slug || '-' || lower(regexp_replace(
      public.transliterate_ru(artist), '[^a-z0-9]+', '-', 'g'
    ));
    base_slug := trim(both '-' from base_slug);
  END IF;
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.tracks WHERE slug = final_slug AND id != NEW.id) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter;
  END LOOP;
  NEW.slug := final_slug;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_track_slug ON public.tracks;
CREATE TRIGGER trg_track_slug
  BEFORE INSERT OR UPDATE OF title ON public.tracks
  FOR EACH ROW EXECUTE FUNCTION public.generate_track_slug();

-- 1f. Slug для профилей (артистов)
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS slug TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_slug ON public.profiles(slug) WHERE slug IS NOT NULL;

CREATE OR REPLACE FUNCTION public.generate_profile_slug() RETURNS TRIGGER AS $$
DECLARE
  base_slug TEXT;
  final_slug TEXT;
  counter INT := 0;
BEGIN
  IF NEW.slug IS NOT NULL AND NEW.slug != '' THEN RETURN NEW; END IF;
  IF NEW.username IS NULL OR NEW.username = '' THEN RETURN NEW; END IF;
  base_slug := lower(regexp_replace(
    public.transliterate_ru(NEW.username), '[^a-z0-9]+', '-', 'g'
  ));
  base_slug := trim(both '-' from base_slug);
  IF base_slug = '' THEN RETURN NEW; END IF;
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.profiles WHERE slug = final_slug AND id != NEW.id) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter;
  END LOOP;
  NEW.slug := final_slug;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_profile_slug ON public.profiles;
CREATE TRIGGER trg_profile_slug
  BEFORE INSERT OR UPDATE OF username ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.generate_profile_slug();

-- 1g. Заполнить slug для существующих данных
UPDATE public.tracks SET title = title WHERE slug IS NULL AND title IS NOT NULL;
UPDATE public.profiles SET username = username WHERE username IS NOT NULL AND (slug IS NULL OR slug = '');

-- 1h. RLS
ALTER TABLE public.seo_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seo_robots_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seo_ai_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admins_manage_seo_metadata" ON public.seo_metadata
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "public_read_seo_metadata" ON public.seo_metadata
  FOR SELECT TO anon, authenticated
  USING (is_active = true);

CREATE POLICY "service_role_seo_metadata" ON public.seo_metadata
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "admins_manage_seo_robots" ON public.seo_robots_rules
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "public_read_seo_robots" ON public.seo_robots_rules
  FOR SELECT TO anon, authenticated
  USING (is_active = true);

CREATE POLICY "service_role_seo_robots" ON public.seo_robots_rules
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "admins_manage_seo_ai_config" ON public.seo_ai_config
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "public_read_seo_ai_config" ON public.seo_ai_config
  FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "service_role_seo_ai_config" ON public.seo_ai_config
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);
