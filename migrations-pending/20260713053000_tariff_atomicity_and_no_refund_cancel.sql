-- Тарифные операции сериализуются на уровне пользователя.
-- Отмена подписки поддерживается только без возврата: доступ сохраняется
-- до конца уже оплаченного периода, автопродление отключается.

DROP FUNCTION IF EXISTS public.cancel_subscription_with_refund(UUID, BOOLEAN);

CREATE OR REPLACE FUNCTION public.cancel_subscription(p_subscription_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_sub RECORD;
BEGIN
  v_caller := NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID;

  SELECT us.user_id
  INTO v_sub
  FROM public.user_subscriptions us
  WHERE us.id = p_subscription_id;

  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'subscription_not_found');
  END IF;

  IF v_caller IS NULL OR (v_caller <> v_sub.user_id AND NOT public.is_admin(v_caller)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_sub.user_id::TEXT, 71001));

  SELECT us.*
  INTO v_sub
  FROM public.user_subscriptions us
  WHERE us.id = p_subscription_id
    AND us.status = 'active'
  FOR UPDATE;

  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'subscription_not_found');
  END IF;

  UPDATE public.user_subscriptions
  SET status = 'canceled',
      canceled_at = now(),
      auto_renew = false
  WHERE id = p_subscription_id
    AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'subscription_not_found');
  END IF;

  INSERT INTO public.subscription_events
    (user_id, subscription_id, event_type, plan_id, amount, metadata)
  VALUES
    (v_sub.user_id, p_subscription_id, 'canceled', v_sub.plan_id, 0,
     jsonb_build_object('refund', 0, 'active_until', v_sub.current_period_end));

  RETURN jsonb_build_object(
    'success', true,
    'active_until', v_sub.current_period_end
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_subscription(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_subscription(UUID) TO authenticated;

-- Блокировка должна быть получена до чтения текущей подписки и расчёта
-- prorated-зачёта. Публичная обёртка оставляет прежний RPC-контракт покупки.
ALTER FUNCTION public.subscribe_to_plan(UUID, UUID, TEXT)
  RENAME TO subscribe_to_plan_unlocked;

CREATE FUNCTION public.subscribe_to_plan(
  p_user_id UUID,
  p_plan_id UUID,
  p_period_type TEXT DEFAULT 'monthly'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_rank INTEGER;
  v_current_rank INTEGER := 0;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 71001));

  SELECT CASE tier_key
    WHEN 'free' THEN 0
    WHEN 'creator' THEN 1
    WHEN 'pro' THEN 2
    WHEN 'label' THEN 3
  END
  INTO v_target_rank
  FROM public.subscription_plans
  WHERE id = p_plan_id
    AND is_active = true;

  IF v_target_rank IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'plan_not_found');
  END IF;

  SELECT CASE sp.tier_key
    WHEN 'free' THEN 0
    WHEN 'creator' THEN 1
    WHEN 'pro' THEN 2
    WHEN 'label' THEN 3
  END
  INTO v_current_rank
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  v_current_rank := COALESCE(v_current_rank, 0);

  IF v_target_rank <= v_current_rank THEN
    RETURN jsonb_build_object('success', false, 'error', 'tariff_upgrade_only');
  END IF;

  RETURN public.subscribe_to_plan_unlocked(p_user_id, p_plan_id, p_period_type);
END;
$$;

REVOKE ALL ON FUNCTION public.subscribe_to_plan_unlocked(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.subscribe_to_plan(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscribe_to_plan(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscribe_to_plan(UUID, UUID, TEXT) TO service_role;

-- Сериализация покупки/смены тарифа устраняет двойные подписки и двойной
-- prorated-зачёт при повторных параллельных запросах одного пользователя.
CREATE OR REPLACE FUNCTION public.lock_tariff_subscription_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::TEXT, 71001));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS lock_tariff_subscription_operation ON public.user_subscriptions;
CREATE TRIGGER lock_tariff_subscription_operation
BEFORE INSERT OR UPDATE ON public.user_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.lock_tariff_subscription_operation();

-- check + consume должны выполняться под одной блокировкой. Это не даёт двум
-- параллельным загрузкам использовать один и тот же последний бесплатный слот.
CREATE OR REPLACE FUNCTION public.lock_track_upload_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::TEXT, 71002));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS lock_track_upload_operation ON public.user_track_uploads;
CREATE TRIGGER lock_track_upload_operation
BEFORE INSERT OR UPDATE ON public.user_track_uploads
FOR EACH ROW
EXECUTE FUNCTION public.lock_track_upload_operation();

-- Триггер user_track_uploads является страховкой, но блокировка должна быть
-- получена до check_track_upload_limit, поэтому добавляем её в consume-функцию.
CREATE OR REPLACE FUNCTION public.acquire_track_upload_lock(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 71002));
END;
$$;

REVOKE ALL ON FUNCTION public.acquire_track_upload_lock(UUID) FROM PUBLIC;

-- Встраиваем раннюю блокировку без дублирования тарифной логики: существующая
-- функция переименовывается во внутреннюю реализацию, публичная обёртка
-- сериализует операцию и вызывает её в той же транзакции.
ALTER FUNCTION public.consume_track_upload_charge(UUID, UUID)
  RENAME TO consume_track_upload_charge_unlocked;

CREATE FUNCTION public.consume_track_upload_charge(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  PERFORM public.acquire_track_upload_lock(p_user_id);
  RETURN public.consume_track_upload_charge_unlocked(p_user_id, p_track_id);
END;
$$;

REVOKE ALL ON FUNCTION public.consume_track_upload_charge_unlocked(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.consume_track_upload_charge(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_track_upload_charge(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_track_upload_charge(UUID, UUID) TO service_role;
