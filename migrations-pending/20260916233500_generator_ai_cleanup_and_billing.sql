-- Simplify generator AI helpers and make lyrics generation billing auditable.

UPDATE public.addon_services
SET is_active = false,
    updated_at = now()
WHERE name IN ('create_prompt', 'auto_prepare');

UPDATE public.addon_services
SET name_ru = 'AI-текст песни',
    description = 'Создание текста песни по описанию',
    provider = 'sunoapi',
    provider_operation = 'generate_lyrics',
    provider_model = NULL,
    base_cost_credits = 0.4,
    price_aipci = 0.4,
    is_active = true,
    sort_order = 12,
    updated_at = now()
WHERE name = 'generate_lyrics';

UPDATE public.addon_services
SET name_ru = 'Создание музыки AI',
    description = 'Создание двух вариантов музыкального трека',
    updated_at = now()
WHERE name = 'generate_music_v6';

CREATE OR REPLACE FUNCTION public.debit_addon_service(
  p_user_id UUID,
  p_service_name TEXT,
  p_description TEXT DEFAULT 'Платная AI-услуга',
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  new_balance INTEGER,
  amount_debited INTEGER,
  service_id UUID,
  base_cost_credits NUMERIC,
  provider TEXT,
  provider_operation TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_service public.addon_services%ROWTYPE;
  v_new_balance INTEGER;
BEGIN
  SELECT * INTO v_service
  FROM public.addon_services
  WHERE name = p_service_name AND is_active = true
  LIMIT 1;

  IF v_service.id IS NULL THEN
    RAISE EXCEPTION 'Service unavailable';
  END IF;
  IF COALESCE(v_service.price_rub, 0) <= 0 THEN
    RAISE EXCEPTION 'Invalid service price';
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_service.price_rub
  WHERE user_id = p_user_id AND balance >= v_service.price_rub
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, balance_before, balance_after, metadata
  ) VALUES (
    p_user_id,
    -v_service.price_rub,
    'debit',
    p_description,
    v_new_balance + v_service.price_rub,
    v_new_balance,
    COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object('service_name', p_service_name)
  );

  RETURN QUERY SELECT
    v_new_balance,
    v_service.price_rub,
    v_service.id,
    COALESCE(v_service.base_cost_credits, 0),
    v_service.provider,
    v_service.provider_operation;
END;
$$;

REVOKE ALL ON FUNCTION public.debit_addon_service(UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.debit_addon_service(UUID, TEXT, TEXT, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.refund_addon_service(
  p_user_id UUID,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Возврат за AI-услугу',
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance INTEGER;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid refund amount';
  END IF;

  UPDATE public.profiles
  SET balance = balance + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;

  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, balance_before, balance_after, metadata
  ) VALUES (
    p_user_id,
    p_amount,
    'refund',
    p_description,
    v_new_balance - p_amount,
    v_new_balance,
    COALESCE(p_metadata, '{}'::jsonb)
  );

  RETURN v_new_balance;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_addon_service(UUID, INTEGER, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refund_addon_service(UUID, INTEGER, TEXT, JSONB) TO service_role;
