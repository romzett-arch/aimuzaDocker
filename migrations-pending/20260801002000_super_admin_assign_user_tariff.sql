CREATE OR REPLACE FUNCTION public.super_admin_assign_user_tariff(
  p_user_id uuid,
  p_plan_id uuid,
  p_duration_days integer DEFAULT 30
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.has_role(v_actor_id, 'super_admin'::public.app_role) THEN
    RAISE EXCEPTION 'Только super_admin может подключать тариф пользователю';
  END IF;

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
  SET status = 'expired',
      auto_renew = false,
      canceled_at = COALESCE(canceled_at, now()),
      updated_at = now()
  WHERE user_id = p_user_id
    AND status IN ('active', 'canceled')
    AND current_period_end > now();

  INSERT INTO public.user_subscriptions (
    user_id,
    plan_id,
    status,
    period_type,
    current_period_start,
    current_period_end,
    auto_renew
  ) VALUES (
    p_user_id,
    p_plan_id,
    'active',
    CASE WHEN p_duration_days >= 365 THEN 'yearly' ELSE 'monthly' END,
    now(),
    v_period_end,
    false
  )
  RETURNING * INTO v_subscription;

  INSERT INTO public.subscription_events (
    user_id,
    subscription_id,
    event_type,
    plan_id,
    amount,
    metadata
  ) VALUES (
    p_user_id,
    v_subscription.id,
    'admin_granted',
    p_plan_id,
    0,
    jsonb_build_object(
      'granted_by', v_actor_id,
      'duration_days', p_duration_days,
      'auto_renew', false
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'subscription_id', v_subscription.id,
    'plan_id', v_plan.id,
    'plan_name', v_plan.name_ru,
    'tier_key', v_plan.tier_key,
    'current_period_end', v_period_end
  );
END;
$$;

REVOKE ALL ON FUNCTION public.super_admin_assign_user_tariff(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.super_admin_assign_user_tariff(uuid, uuid, integer) TO authenticated;
