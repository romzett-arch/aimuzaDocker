-- Завершённый контракт тарифов: только реально работающие преимущества,
-- серверное применение приоритета конкурсов/поддержки и защита radio stats.

-- Старые поля не соответствуют действующим услугам и не должны создавать
-- фиктивные преимущества в админке или API.
UPDATE public.subscription_plans
SET generation_credits = 0,
    priority_generation = false,
    service_quotas = '{}'::jsonb,
    no_watermark = false,
    commercial_license = false,
    radio_guaranteed_slots_weekly = 0,
    radio_api_access = false,
    updated_at = now();

UPDATE public.subscription_plans
SET features = '[
  "20 треков/месяц бесплатно",
  "Сверх лимита — 20₽/трек",
  "Буст 2×/день по 1 часу",
  "Бейдж PRO 🔥",
  "Приоритет в конкурсах",
  "Детальная аналитика",
  "2 Blockchain-сертификата/мес",
  "Ускоренная модерация (~24ч)",
  "Радио: приоритет ×1.5",
  "Скидка на радио-аукцион 20%",
  "Статистика радио в ЛК",
  "БЕЗ РЕКЛАМЫ везде"
]'::jsonb,
updated_at = now()
WHERE tier_key = 'pro';

UPDATE public.subscription_plans
SET features = '[
  "30 треков/месяц бесплатно",
  "Сверх лимита — 20₽/трек",
  "Буст 3×/день на 24 часа",
  "Золотой бейдж LABEL 👑",
  "Максимальный приоритет в конкурсах",
  "Расширенная аналитика + экспорт",
  "3 Blockchain-сертификата/мес",
  "Экспресс-модерация (~12ч)",
  "Радио: приоритет ×2.5",
  "Скидка на радио-аукцион 50%",
  "Расширенная статистика радио",
  "БЕЗ РЕКЛАМЫ везде",
  "Приоритетная поддержка"
]'::jsonb,
updated_at = now()
WHERE tier_key = 'label';

-- Приоритет конкурса фиксируется в самой заявке и доступен для честной
-- сортировки даже после окончания подписки.
ALTER TABLE public.contest_entries
  ADD COLUMN IF NOT EXISTS tariff_priority INTEGER NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.trg_apply_contest_tariff_priority()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
BEGIN
  v_tier := public.get_user_subscription_tier(NEW.user_id);
  NEW.tariff_priority := COALESCE((v_tier->>'contest_priority')::INTEGER, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS apply_contest_tariff_priority ON public.contest_entries;
CREATE TRIGGER apply_contest_tariff_priority
BEFORE INSERT ON public.contest_entries
FOR EACH ROW
EXECUTE FUNCTION public.trg_apply_contest_tariff_priority();

UPDATE public.contest_entries ce
SET tariff_priority = COALESCE((public.get_user_subscription_tier(ce.user_id)->>'contest_priority')::INTEGER, 0);

CREATE INDEX IF NOT EXISTS idx_contest_entries_tariff_priority
  ON public.contest_entries(contest_id, tariff_priority DESC, score DESC, created_at ASC);

-- LABEL получает реальный приоритет в очереди поддержки.
CREATE OR REPLACE FUNCTION public.trg_apply_support_tariff_priority()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
BEGIN
  IF NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_tier := public.get_user_subscription_tier(NEW.user_id);
  IF (v_tier->>'tier_key') = 'label' THEN
    NEW.priority := 'high';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS apply_support_tariff_priority ON public.support_tickets;
CREATE TRIGGER apply_support_tariff_priority
BEFORE INSERT ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.trg_apply_support_tariff_priority();

CREATE INDEX IF NOT EXISTS idx_support_tickets_priority_queue
  ON public.support_tickets(
    (CASE priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END),
    created_at ASC
  )
  WHERE status IN ('open', 'in_progress');

-- Радио-статистика содержит приватную аналитику: владелец или администратор.
ALTER FUNCTION public.get_my_radio_stats(UUID) RENAME TO get_my_radio_stats_unlocked;

CREATE FUNCTION public.get_my_radio_stats(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('available', false, 'error', 'unauthorized');
  END IF;
  RETURN public.get_my_radio_stats_unlocked(p_user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_radio_stats_unlocked(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_radio_stats(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_radio_stats(UUID) TO authenticated;

-- Контракт миграции: не позволяем применить неполную матрицу.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscription_plans
    WHERE generation_credits <> 0
       OR priority_generation
       OR service_quotas <> '{}'::jsonb
       OR no_watermark
       OR commercial_license
       OR radio_guaranteed_slots_weekly <> 0
       OR radio_api_access
  ) THEN
    RAISE EXCEPTION 'tariff_legacy_features_must_be_disabled';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE tier_key='pro' AND radio_stats_enabled AND NOT radio_stats_extended AND ad_free) OR
     NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE tier_key='label' AND radio_stats_enabled AND radio_stats_extended AND ad_free) THEN
    RAISE EXCEPTION 'tariff_radio_and_adfree_contract_invalid';
  END IF;
END;
$$;

