-- ============================================================
-- PREMIUM SUBSCRIPTIONS — Оставшиеся интеграции
-- allocate_guaranteed_radio_slots, проверки модерации,
-- маркетплейса, конкурсов
-- ============================================================

-- ─── 1. allocate_guaranteed_radio_slots ──────────────────────
-- Cron: каждый понедельник. Выделяет гарантированные радио-слоты
-- подписчикам PRO/LABEL.

CREATE OR REPLACE FUNCTION public.allocate_guaranteed_radio_slots()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec RECORD;
  v_allocated INTEGER := 0;
  v_slot_id UUID;
BEGIN
  FOR v_rec IN
    SELECT us.user_id, sp.radio_guaranteed_slots_weekly, sp.tier_key
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.status = 'active'
      AND us.current_period_end > now()
      AND sp.radio_guaranteed_slots_weekly > 0
  LOOP
    -- Создать гарантированные слоты на неделю
    FOR i IN 1..v_rec.radio_guaranteed_slots_weekly LOOP
      INSERT INTO public.radio_slots (
        user_id, status, slot_type, start_time, end_time
      ) VALUES (
        v_rec.user_id, 'reserved', 'guaranteed',
        now() + ((i - 1) || ' days')::INTERVAL,
        now() + (i || ' days')::INTERVAL
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_slot_id;

      IF v_slot_id IS NOT NULL THEN
        v_allocated := v_allocated + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('allocated', v_allocated);
END;
$$;

GRANT EXECUTE ON FUNCTION public.allocate_guaranteed_radio_slots() TO authenticated;


-- ─── 2. check_marketplace_access ─────────────────────────────
-- Проверяет, может ли пользователь продавать на маркетплейсе

CREATE OR REPLACE FUNCTION public.check_marketplace_access(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
  v_can_sell BOOLEAN;
BEGIN
  v_tier := public.get_user_subscription_tier(p_user_id);
  v_can_sell := COALESCE((v_tier->>'can_sell_marketplace')::BOOLEAN, false);

  RETURN jsonb_build_object(
    'can_sell', v_can_sell,
    'tier_key', v_tier->>'tier_key',
    'plan_name', v_tier->>'plan_name'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_marketplace_access(UUID) TO authenticated;


-- ─── 3. check_contest_access ─────────────────────────────────
-- Проверяет, может ли пользователь участвовать в конкурсах

CREATE OR REPLACE FUNCTION public.check_contest_access(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
  v_can_participate BOOLEAN;
  v_priority INTEGER;
BEGIN
  v_tier := public.get_user_subscription_tier(p_user_id);
  v_can_participate := COALESCE((v_tier->>'can_participate_contests')::BOOLEAN, false);
  v_priority := COALESCE((v_tier->>'contest_priority')::INTEGER, 0);

  RETURN jsonb_build_object(
    'can_participate', v_can_participate,
    'contest_priority', v_priority,
    'tier_key', v_tier->>'tier_key'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_contest_access(UUID) TO authenticated;


-- ─── 4. Модерация: сортировка по moderation_priority ─────────
-- Обновляем RPC получения очереди модерации (если есть)
-- Добавляем VIEW для удобной выборки с приоритетом подписки

CREATE OR REPLACE VIEW public.moderation_queue_prioritized AS
SELECT
  t.id AS track_id,
  t.title,
  t.user_id,
  t.moderation_status,
  t.created_at AS submitted_at,
  COALESCE(sp.moderation_priority, 0) AS sub_priority,
  COALESCE(sp.moderation_sla_hours, 168) AS sla_hours,
  sp.tier_key AS author_tier
FROM public.tracks t
LEFT JOIN public.user_subscriptions us
  ON us.user_id = t.user_id AND us.status = 'active' AND us.current_period_end > now()
LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
WHERE t.moderation_status = 'pending'
ORDER BY
  COALESCE(sp.moderation_priority, 0) DESC,
  t.created_at ASC;
