-- Скидка на генерацию должна сохраняться до конца already paid периода,
-- даже если автопродление отключено и статус подписки стал canceled.

CREATE OR REPLACE FUNCTION public.debit_for_generation(
  p_user_id UUID,
  p_addon_service_ids UUID[] DEFAULT '{}',
  p_description TEXT DEFAULT 'Генерация трека'
)
RETURNS TABLE(new_balance INTEGER, amount_debited INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_generation_price INTEGER;
  v_discount_percent INTEGER;
  v_has_subscription BOOLEAN;
  v_addons_total INTEGER := 0;
  v_base_price INTEGER;
  v_total INTEGER;
  v_new_balance INTEGER;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR (v_caller != p_user_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE((value)::integer, 28) INTO v_generation_price
  FROM public.settings WHERE key = 'generation_price' LIMIT 1;

  SELECT COALESCE((value)::integer, 20) INTO v_discount_percent
  FROM public.settings WHERE key = 'subscriber_discount_percent' LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM public.user_subscriptions s
    WHERE s.user_id = p_user_id
      AND s.status IN ('active', 'canceled')
      AND s.current_period_end > now()
  ) INTO v_has_subscription;

  v_base_price := v_generation_price;
  IF v_has_subscription AND v_discount_percent > 0 THEN
    v_base_price := v_generation_price - (v_generation_price * v_discount_percent / 100);
  END IF;

  IF array_length(p_addon_service_ids, 1) > 0 THEN
    SELECT COALESCE(SUM(price_rub), 0)::integer INTO v_addons_total
    FROM public.addon_services
    WHERE id = ANY(p_addon_service_ids) AND is_active = true;
  END IF;

  v_total := v_base_price + v_addons_total;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;

  UPDATE public.profiles
    SET balance = balance - v_total
    WHERE user_id = p_user_id AND balance >= v_total
    RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, balance_before, balance_after)
  VALUES
    (p_user_id, -v_total, 'debit', p_description, v_new_balance + v_total, v_new_balance);

  RETURN QUERY SELECT v_new_balance, v_total;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debit_for_generation(UUID, UUID[], TEXT) TO authenticated;

COMMENT ON FUNCTION public.debit_for_generation IS 'Списание за генерацию с серверной валидацией цены. Учитывает generation_price, subscriber_discount и addon_services, включая canceled-подписки до current_period_end.';
