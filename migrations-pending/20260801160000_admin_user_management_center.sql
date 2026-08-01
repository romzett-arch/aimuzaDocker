-- Complete the admin user card contracts: tariff lifecycle, audited XP,
-- all-time finance totals, and last sign-in visibility.

DROP FUNCTION IF EXISTS public.super_admin_assign_user_tariff(uuid, uuid, integer);

CREATE FUNCTION public.super_admin_assign_user_tariff(
  p_user_id uuid,
  p_plan_id uuid,
  p_duration_days integer,
  p_reason text,
  p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_plan public.subscription_plans%ROWTYPE;
  v_subscription public.user_subscriptions%ROWTYPE;
  v_period_end timestamptz;
  v_reason text := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
  v_comment text := NULLIF(BTRIM(COALESCE(p_comment, '')), '');
BEGIN
  IF v_actor_id IS NULL OR NOT public.has_role(v_actor_id, 'super_admin'::public.app_role) THEN
    RAISE EXCEPTION 'Только super_admin может подключать тариф пользователю';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину выдачи тарифа'; END IF;
  IF p_duration_days IS NULL OR p_duration_days < 1 OR p_duration_days > 3650 THEN
    RAISE EXCEPTION 'Срок тарифа должен быть от 1 до 3650 дней';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'Пользователь не найден';
  END IF;

  SELECT * INTO v_plan
  FROM public.subscription_plans
  WHERE id = p_plan_id AND is_active = true;
  IF NOT FOUND OR v_plan.tier_key = 'free' THEN
    RAISE EXCEPTION 'Выберите активный платный тариф';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 71001));
  v_period_end := now() + make_interval(days => p_duration_days);

  UPDATE public.user_subscriptions
  SET status = 'expired', auto_renew = false,
      canceled_at = COALESCE(canceled_at, now()), updated_at = now()
  WHERE user_id = p_user_id
    AND status IN ('active', 'canceled')
    AND current_period_end > now();

  INSERT INTO public.user_subscriptions (
    user_id, plan_id, status, period_type, current_period_start,
    current_period_end, auto_renew
  ) VALUES (
    p_user_id, p_plan_id, 'active',
    CASE WHEN p_duration_days >= 365 THEN 'yearly' ELSE 'monthly' END,
    now(), v_period_end, false
  ) RETURNING * INTO v_subscription;

  INSERT INTO public.subscription_events
    (user_id, subscription_id, event_type, plan_id, amount, metadata)
  VALUES (
    p_user_id, v_subscription.id, 'admin_granted', p_plan_id, 0,
    jsonb_build_object(
      'granted_by', v_actor_id, 'duration_days', p_duration_days,
      'auto_renew', false, 'reason', v_reason, 'comment', v_comment
    )
  );

  INSERT INTO public.role_change_logs
    (user_id, changed_by, action, reason, metadata)
  VALUES (
    p_user_id, v_actor_id, 'tariff_granted', v_reason,
    jsonb_build_object(
      'subscription_id', v_subscription.id, 'plan_id', v_plan.id,
      'plan_name', v_plan.name_ru, 'tier_key', v_plan.tier_key,
      'duration_days', p_duration_days, 'period_end', v_period_end,
      'comment', v_comment
    )
  );

  INSERT INTO public.notifications
    (user_id, actor_id, type, title, message, target_type, target_id, metadata)
  VALUES (
    p_user_id, v_actor_id, 'system',
    'Вам подключён тариф «' || COALESCE(v_plan.name_ru, v_plan.name) || '»',
    'Тариф действует до ' || to_char(v_period_end AT TIME ZONE 'Europe/Moscow', 'DD.MM.YYYY HH24:MI') ||
      '. Причина: ' || v_reason || CASE WHEN v_comment IS NULL THEN '' ELSE '. ' || v_comment END,
    'subscription', v_subscription.id,
    jsonb_build_object('event', 'admin_granted', 'plan_id', v_plan.id, 'reason', v_reason)
  );

  RETURN jsonb_build_object(
    'success', true, 'subscription_id', v_subscription.id,
    'plan_id', v_plan.id, 'plan_name', v_plan.name_ru,
    'tier_key', v_plan.tier_key, 'current_period_end', v_period_end
  );
END;
$$;

REVOKE ALL ON FUNCTION public.super_admin_assign_user_tariff(uuid, uuid, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.super_admin_assign_user_tariff(uuid, uuid, integer, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.super_admin_revoke_user_tariff(
  p_user_id uuid,
  p_reason text,
  p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reason text := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
  v_comment text := NULLIF(BTRIM(COALESCE(p_comment, '')), '');
  v_subscription record;
  v_revoked_count integer := 0;
BEGIN
  IF v_actor_id IS NULL OR NOT public.has_role(v_actor_id, 'super_admin'::public.app_role) THEN
    RAISE EXCEPTION 'Только super_admin может снимать тариф у пользователя';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину снятия тарифа'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'Пользователь не найден';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 71001));

  FOR v_subscription IN
    SELECT us.id, us.plan_id, sp.name_ru, sp.name, sp.tier_key
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.user_id = p_user_id
      AND us.status IN ('active', 'canceled')
      AND us.current_period_end > now()
      AND sp.tier_key <> 'free'
    FOR UPDATE OF us
  LOOP
    UPDATE public.user_subscriptions
    SET status = 'expired', current_period_end = now(), canceled_at = now(),
        auto_renew = false, updated_at = now()
    WHERE id = v_subscription.id;

    INSERT INTO public.subscription_events
      (user_id, subscription_id, event_type, plan_id, amount, metadata)
    VALUES (
      p_user_id, v_subscription.id, 'admin_revoked', v_subscription.plan_id, 0,
      jsonb_build_object('revoked_by', v_actor_id, 'reason', v_reason, 'comment', v_comment)
    );
    v_revoked_count := v_revoked_count + 1;
  END LOOP;

  IF v_revoked_count = 0 THEN RAISE EXCEPTION 'У пользователя нет активного платного тарифа'; END IF;

  INSERT INTO public.role_change_logs (user_id, changed_by, action, reason, metadata)
  VALUES (
    p_user_id, v_actor_id, 'tariff_revoked', v_reason,
    jsonb_build_object('revoked_count', v_revoked_count, 'comment', v_comment, 'new_tier', 'free')
  );

  INSERT INTO public.notifications
    (user_id, actor_id, type, title, message, target_type, target_id, metadata)
  VALUES (
    p_user_id, v_actor_id, 'system', 'Тариф отключён',
    'Ваш аккаунт переведён на тариф «Новичок». Причина: ' || v_reason ||
      CASE WHEN v_comment IS NULL THEN '' ELSE '. ' || v_comment END,
    'profile', p_user_id,
    jsonb_build_object('event', 'admin_revoked', 'reason', v_reason, 'tier_key', 'free')
  );

  RETURN jsonb_build_object('success', true, 'revoked_count', v_revoked_count, 'tier_key', 'free');
END;
$$;

REVOKE ALL ON FUNCTION public.super_admin_revoke_user_tariff(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.super_admin_revoke_user_tariff(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_adjust_user_xp(
  p_user_id uuid,
  p_amount integer,
  p_category text,
  p_reason text,
  p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reason text := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
  v_comment text := NULLIF(BTRIM(COALESCE(p_comment, '')), '');
  v_applied integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину изменения XP'; END IF;
  IF p_amount IS NULL OR p_amount = 0 OR abs(p_amount) > 100000 THEN
    RAISE EXCEPTION 'Количество XP должно быть от -100000 до 100000 и не равно нулю';
  END IF;
  IF p_category NOT IN ('forum', 'music', 'social') THEN RAISE EXCEPTION 'Неизвестная категория XP'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  v_applied := public.fn_add_xp(p_user_id, p_amount, p_category, true);

  INSERT INTO public.role_change_logs (user_id, changed_by, action, reason, metadata)
  VALUES (
    p_user_id, v_actor_id, 'xp_adjusted', v_reason,
    jsonb_build_object('requested_amount', p_amount, 'applied_amount', v_applied,
      'category', p_category, 'comment', v_comment)
  );

  INSERT INTO public.notifications
    (user_id, actor_id, type, title, message, target_type, target_id, metadata)
  VALUES (
    p_user_id, v_actor_id, 'system', 'XP изменён администрацией',
    (CASE WHEN v_applied > 0 THEN 'Начислено ' ELSE 'Списано ' END) || abs(v_applied)::text ||
      ' XP. Причина: ' || v_reason || CASE WHEN v_comment IS NULL THEN '' ELSE '. ' || v_comment END,
    'profile', p_user_id,
    jsonb_build_object('event', 'xp_adjusted', 'amount', v_applied, 'category', p_category, 'reason', v_reason)
  );

  RETURN jsonb_build_object('success', true, 'applied_amount', v_applied);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_adjust_user_xp(uuid, integer, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_adjust_user_xp(uuid, integer, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_get_user_financial_summary(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;

  SELECT jsonb_build_object(
    'real_topups', COALESCE(SUM(amount) FILTER (WHERE type = 'topup' AND amount > 0), 0),
    'real_spent', COALESCE(SUM(abs(amount)) FILTER (WHERE amount < 0 AND type <> 'refund'), 0),
    'admin_grants', COALESCE(SUM(amount) FILTER (WHERE type = 'admin' AND amount > 0), 0),
    'refunds', COALESCE(SUM(abs(amount)) FILTER (WHERE type = 'refund'), 0),
    'transaction_count', COUNT(*)
  ) INTO v_result
  FROM public.balance_transactions
  WHERE user_id = p_user_id;

  RETURN v_result || jsonb_build_object(
    'current_balance', COALESCE((SELECT balance FROM public.profiles WHERE user_id = p_user_id), 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_user_financial_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_user_financial_summary(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.get_user_emails(uuid[]);
CREATE FUNCTION public.get_user_emails(p_user_ids uuid[] DEFAULT NULL)
RETURNS TABLE(user_id uuid, email text, last_sign_in_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;
  RETURN QUERY
  SELECT u.id, u.email::text, u.last_sign_in_at
  FROM auth.users u
  WHERE p_user_ids IS NULL OR u.id = ANY(p_user_ids);
END;
$$;

REVOKE ALL ON FUNCTION public.get_user_emails(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_emails(uuid[]) TO authenticated;

