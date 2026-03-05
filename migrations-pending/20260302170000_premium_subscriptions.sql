-- ============================================================
-- PREMIUM SUBSCRIPTIONS — Фаза 1: Схема БД + Seed данные
-- 4 тарифных плана: FREE / CREATOR / PRO / LABEL
-- ============================================================

-- ─── 1. Расширение subscription_plans ──────────────────────

-- Идентификация тира
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS tier_key TEXT UNIQUE;

-- Лимиты загрузки треков
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS tracks_free_monthly INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS tracks_free_daily INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS tracks_monthly_hard_limit INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS extra_track_price INTEGER NOT NULL DEFAULT 20;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS free_track_pricing JSONB DEFAULT NULL;

-- Бусты
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS boosts_per_day INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS boost_duration_hours INTEGER NOT NULL DEFAULT 1;

-- Депонирование
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS deposits_free_monthly INTEGER NOT NULL DEFAULT 0;

-- Радио
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_weight_multiplier NUMERIC NOT NULL DEFAULT 1.0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_guaranteed_slots_weekly INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_auction_discount_pct INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_stats_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_stats_extended BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS radio_api_access BOOLEAN NOT NULL DEFAULT false;

-- Доступ и привилегии
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS ad_free BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS moderation_priority INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS moderation_sla_hours INTEGER NOT NULL DEFAULT 168;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS can_sell_marketplace BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS can_participate_contests BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS contest_priority INTEGER NOT NULL DEFAULT 0;

-- Автопродление в user_subscriptions
ALTER TABLE public.user_subscriptions ADD COLUMN IF NOT EXISTS auto_renew BOOLEAN NOT NULL DEFAULT true;


-- ─── 2. Таблица user_track_uploads ─────────────────────────

CREATE TABLE IF NOT EXISTS public.user_track_uploads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  upload_date DATE NOT NULL DEFAULT CURRENT_DATE,
  price_charged INTEGER NOT NULL DEFAULT 0,
  is_free BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_track_uploads_user_date
  ON public.user_track_uploads(user_id, upload_date);
CREATE INDEX IF NOT EXISTS idx_user_track_uploads_user_month
  ON public.user_track_uploads(user_id, (date_trunc('month', upload_date::timestamptz)));

ALTER TABLE public.user_track_uploads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own uploads" ON public.user_track_uploads
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "System can insert uploads" ON public.user_track_uploads
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Admins can manage uploads" ON public.user_track_uploads
  FOR ALL USING (public.is_admin(auth.uid()));


-- ─── 3. Таблица subscription_events ────────────────────────

CREATE TABLE IF NOT EXISTS public.subscription_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  subscription_id UUID REFERENCES public.user_subscriptions(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  plan_id UUID REFERENCES public.subscription_plans(id) ON DELETE SET NULL,
  amount INTEGER NOT NULL DEFAULT 0,
  metadata JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscription_events_user
  ON public.subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_subscription_events_type
  ON public.subscription_events(event_type);

ALTER TABLE public.subscription_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own subscription events" ON public.subscription_events
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admins can manage subscription events" ON public.subscription_events
  FOR ALL USING (public.is_admin(auth.uid()));


-- ─── 4. Seed: 4 тарифных плана ─────────────────────────────

-- Удаляем старые планы (сайт на стадии разработки, активных подписок нет)
DELETE FROM public.subscription_plans;

-- FREE — «Новичок»
INSERT INTO public.subscription_plans (
  name, name_ru, description, tier_key,
  price_monthly, price_yearly,
  tracks_free_monthly, tracks_free_daily, tracks_monthly_hard_limit,
  extra_track_price, free_track_pricing,
  boosts_per_day, boost_duration_hours,
  deposits_free_monthly,
  radio_weight_multiplier, radio_guaranteed_slots_weekly, radio_auction_discount_pct,
  radio_stats_enabled, radio_stats_extended, radio_api_access,
  ad_free, moderation_priority, moderation_sla_hours,
  can_sell_marketplace, can_participate_contests, contest_priority,
  generation_credits, priority_generation,
  badge_emoji, no_watermark, commercial_license,
  features, service_quotas,
  is_active, sort_order
) VALUES (
  'free', 'Новичок', 'Базовый бесплатный план', 'free',
  0, 0,
  1, 3, 15,
  0, '[{"nth":1,"price":0},{"nth":2,"price":10},{"nth":3,"price":30}]'::jsonb,
  0, 0,
  0,
  1.0, 0, 0,
  false, false, false,
  false, 0, 168,
  false, false, 0,
  0, false,
  NULL, false, false,
  '["1 бесплатный трек/день","До 3 треков/день (2-й=10₽, 3-й=30₽)","Лимит 15 треков/месяц","Прослушивание всех треков","Лайки, комментарии, форум","Подача на дистрибуцию (~7 дней)","Стартовый баланс 50₽"]'::jsonb,
  '{}'::jsonb,
  true, 0
);

-- CREATOR — «Музыкант» (399₽/мес)
INSERT INTO public.subscription_plans (
  name, name_ru, description, tier_key,
  price_monthly, price_yearly,
  tracks_free_monthly, tracks_free_daily, tracks_monthly_hard_limit,
  extra_track_price, free_track_pricing,
  boosts_per_day, boost_duration_hours,
  deposits_free_monthly,
  radio_weight_multiplier, radio_guaranteed_slots_weekly, radio_auction_discount_pct,
  radio_stats_enabled, radio_stats_extended, radio_api_access,
  ad_free, moderation_priority, moderation_sla_hours,
  can_sell_marketplace, can_participate_contests, contest_priority,
  generation_credits, priority_generation,
  badge_emoji, no_watermark, commercial_license,
  features, service_quotas,
  is_active, sort_order
) VALUES (
  'creator', 'Музыкант', 'Для активных авторов', 'creator',
  399, 3990,
  20, 0, 0,
  20, NULL,
  1, 1,
  1,
  1.0, 0, 0,
  false, false, false,
  false, 1, 72,
  true, true, 0,
  0, false,
  '🎵', false, false,
  '["20 треков/месяц бесплатно","Сверх лимита — 20₽/трек","Буст 1×/день на 1 час","Бейдж Creator","Участие в конкурсах","Маркетплейс (продажа)","1 Blockchain-сертификат/мес","Приоритетная модерация (~3 дня)"]'::jsonb,
  '{}'::jsonb,
  true, 1
);

-- PRO — «Артист» (699₽/мес) 🔥 ПОПУЛЯРНЫЙ
INSERT INTO public.subscription_plans (
  name, name_ru, description, tier_key,
  price_monthly, price_yearly,
  tracks_free_monthly, tracks_free_daily, tracks_monthly_hard_limit,
  extra_track_price, free_track_pricing,
  boosts_per_day, boost_duration_hours,
  deposits_free_monthly,
  radio_weight_multiplier, radio_guaranteed_slots_weekly, radio_auction_discount_pct,
  radio_stats_enabled, radio_stats_extended, radio_api_access,
  ad_free, moderation_priority, moderation_sla_hours,
  can_sell_marketplace, can_participate_contests, contest_priority,
  generation_credits, priority_generation,
  badge_emoji, no_watermark, commercial_license,
  features, service_quotas,
  is_active, sort_order
) VALUES (
  'pro', 'Артист', 'Максимум возможностей для артиста', 'pro',
  699, 6990,
  30, 0, 0,
  20, NULL,
  3, 1,
  3,
  1.5, 2, 20,
  true, false, false,
  true, 2, 24,
  true, true, 1,
  0, true,
  '🔥', true, true,
  '["30 треков/месяц бесплатно","Сверх лимита — 20₽/трек","Буст 3×/день (1ч) или 1×сутки","Бейдж PRO 🔥","Приоритет в конкурсах","Детальная аналитика","3 Blockchain-сертификата/мес","Ускоренная модерация (~24ч)","Радио: приоритет ×1.5 + 2 слота/нед","Скидка на радио-аукцион 20%","Статистика радио в ЛК","БЕЗ РЕКЛАМЫ везде"]'::jsonb,
  '{}'::jsonb,
  true, 2
);

-- LABEL — «Лейбл» (1699₽/мес) 👑
INSERT INTO public.subscription_plans (
  name, name_ru, description, tier_key,
  price_monthly, price_yearly,
  tracks_free_monthly, tracks_free_daily, tracks_monthly_hard_limit,
  extra_track_price, free_track_pricing,
  boosts_per_day, boost_duration_hours,
  deposits_free_monthly,
  radio_weight_multiplier, radio_guaranteed_slots_weekly, radio_auction_discount_pct,
  radio_stats_enabled, radio_stats_extended, radio_api_access,
  ad_free, moderation_priority, moderation_sla_hours,
  can_sell_marketplace, can_participate_contests, contest_priority,
  generation_credits, priority_generation,
  badge_emoji, no_watermark, commercial_license,
  features, service_quotas,
  is_active, sort_order
) VALUES (
  'label', 'Лейбл', 'Для лейблов и профессионалов', 'label',
  1699, 16990,
  50, 0, 0,
  20, NULL,
  5, 24,
  10,
  2.5, 5, 50,
  true, true, true,
  true, 3, 12,
  true, true, 2,
  0, true,
  '👑', true, true,
  '["50 треков/месяц бесплатно","Сверх лимита — 20₽/трек","Буст 5×/день на сутки","Золотой бейдж LABEL 👑","Максимальный приоритет в конкурсах","Расширенная аналитика + экспорт","10 Blockchain-сертификатов/мес","Экспресс-модерация (~12ч)","Радио: приоритет ×2.5 + 5 слотов/нед","Скидка на радио-аукцион 50%","Расширенная статистика радио + API","БЕЗ РЕКЛАМЫ везде","Приоритетная поддержка"]'::jsonb,
  '{}'::jsonb,
  true, 3
);


-- ─── 5. Триггер: стартовый баланс 50₽ для новых пользователей ──

CREATE OR REPLACE FUNCTION public.fn_grant_welcome_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_welcome_amount INTEGER := 50;
BEGIN
  -- Начисляем стартовый баланс только если профиль уже создан и баланс = 0
  UPDATE public.profiles
    SET balance = balance + v_welcome_amount
    WHERE user_id = NEW.id
      AND balance = 0;

  IF FOUND THEN
    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (NEW.id, v_welcome_amount, 'bonus', 'Приветственный бонус 50₽', 0, v_welcome_amount);
  END IF;

  RETURN NEW;
END;
$$;

-- Триггер срабатывает AFTER INSERT на auth.users (после создания профиля триггером)
-- Используем отложенный триггер чтобы profiles уже существовал
DROP TRIGGER IF EXISTS trg_welcome_balance ON auth.users;
CREATE TRIGGER trg_welcome_balance
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_grant_welcome_balance();


-- ─── 6. Grants ─────────────────────────────────────────────

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON public.user_track_uploads TO authenticated;
    GRANT INSERT ON public.user_track_uploads TO authenticated;
    GRANT SELECT ON public.subscription_events TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT SELECT ON public.subscription_plans TO anon;
  END IF;
END $$;
