-- Восстанавливает guard-функции, от которых зависят server-side trigger'ы
-- маркетплейса и конкурсов. Нужна для локальных/старых баз, где миграция
-- premium_remaining_integrations могла не доехать или быть частично потеряна.

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
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object(
      'can_sell', false,
      'tier_key', 'unknown',
      'plan_name', null,
      'error', 'unauthorized'
    );
  END IF;

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
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object(
      'can_participate', false,
      'contest_priority', 0,
      'tier_key', 'unknown',
      'error', 'unauthorized'
    );
  END IF;

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
