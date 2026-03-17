-- Fix: админское начисление не должно маскироваться под доход от продажи.

CREATE OR REPLACE FUNCTION public.admin_grant_user_income(
  p_user_id UUID,
  p_amount INTEGER,
  p_source_name TEXT,
  p_purpose TEXT,
  p_comment TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
  v_grant_id UUID := gen_random_uuid();
  v_source_name TEXT := NULLIF(BTRIM(COALESCE(p_source_name, '')), '');
  v_purpose TEXT := NULLIF(BTRIM(COALESCE(p_purpose, '')), '');
  v_comment TEXT := NULLIF(BTRIM(COALESCE(p_comment, '')), '');
  v_description TEXT;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  IF NOT (
    public.has_role(v_admin_id, 'admin')
    OR public.has_role(v_admin_id, 'super_admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно прав');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Сумма должна быть больше нуля');
  END IF;

  IF v_source_name IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Укажите, от кого поступление');
  END IF;

  IF v_purpose IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Укажите, за что поступление');
  END IF;

  SELECT COALESCE(balance, 0)
  INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Пользователь не найден');
  END IF;

  v_description := 'Поступило ' || p_amount::TEXT || ' ₽ от ' || v_source_name || ' за ' || v_purpose;

  IF v_comment IS NOT NULL THEN
    v_description := v_description || '. ' || v_comment;
  END IF;

  UPDATE public.profiles
  SET balance = COALESCE(balance, 0) + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_balance_after;

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    balance_before,
    balance_after,
    type,
    description,
    reference_id,
    reference_type,
    metadata
  )
  VALUES (
    p_user_id,
    p_amount,
    v_balance_before,
    v_balance_after,
    'admin',
    v_description,
    v_grant_id,
    'admin_grant',
    jsonb_build_object(
      'source_name', v_source_name,
      'purpose', v_purpose,
      'comment', v_comment,
      'granted_by', v_admin_id
    )
  );

  INSERT INTO public.seller_earnings (
    user_id,
    amount,
    source_type,
    source_id,
    platform_fee,
    net_amount,
    status,
    metadata
  )
  VALUES (
    p_user_id,
    p_amount,
    'admin_grant',
    v_grant_id,
    -p_amount,
    p_amount,
    'available',
    jsonb_build_object(
      'source_name', v_source_name,
      'purpose', v_purpose,
      'comment', v_comment,
      'granted_by', v_admin_id
    )
  );

  INSERT INTO public.notifications (
    user_id,
    type,
    title,
    message,
    actor_id,
    target_type,
    target_id,
    metadata
  )
  VALUES (
    p_user_id,
    'system',
    'Начисление от администрации',
    v_description,
    v_admin_id,
    'profile',
    p_user_id,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'amount', p_amount,
      'source_name', v_source_name,
      'purpose', v_purpose
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'grant_id', v_grant_id,
    'balance_before', v_balance_before,
    'balance_after', v_balance_after,
    'amount', p_amount
  );
END;
$$;
