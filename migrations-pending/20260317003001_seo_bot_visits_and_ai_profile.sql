-- SEO bot visits + расширенные AI-настройки для SEO-центра

CREATE TABLE IF NOT EXISTS public.seo_bot_visits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  visited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  bot_family TEXT NOT NULL,
  user_agent TEXT,
  request_path TEXT NOT NULL,
  query_string TEXT,
  referer TEXT,
  response_status INTEGER,
  source_layer TEXT NOT NULL,
  ip_hash TEXT
);

CREATE INDEX IF NOT EXISTS idx_seo_bot_visits_visited_at ON public.seo_bot_visits (visited_at DESC);
CREATE INDEX IF NOT EXISTS idx_seo_bot_visits_bot_family ON public.seo_bot_visits (bot_family);
CREATE INDEX IF NOT EXISTS idx_seo_bot_visits_request_path ON public.seo_bot_visits (request_path);

ALTER TABLE public.seo_bot_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_read_seo_bot_visits" ON public.seo_bot_visits;
CREATE POLICY "admins_read_seo_bot_visits" ON public.seo_bot_visits
  FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "service_role_manage_seo_bot_visits" ON public.seo_bot_visits;
CREATE POLICY "service_role_manage_seo_bot_visits" ON public.seo_bot_visits
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

INSERT INTO public.seo_ai_config (config_key, config_value, description)
VALUES
  (
    'product_profile',
    'AIMUZA — экосистема, где AI-музыка, сообщество артистов и дистрибуция равноправны.',
    'Краткое позиционирование продукта для SEO-генерации'
  ),
  (
    'forbidden_claims',
    'бесплатно; номер 1; гарантированный успех; лучший без подтверждения',
    'Список запрещённых или требующих подтверждения формулировок'
  )
ON CONFLICT (config_key) DO UPDATE
SET
  config_value = EXCLUDED.config_value,
  description = EXCLUDED.description,
  updated_at = now();
