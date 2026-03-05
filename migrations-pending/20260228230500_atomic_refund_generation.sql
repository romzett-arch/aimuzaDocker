-- Атомарный возврат средств при ошибке генерации.
-- Исправляет race condition: SELECT balance -> UPDATE balance + cost
-- заменено на единый UPDATE balance = balance + cost.
-- Используется в suno-callback/errors.ts (handleFailedTracksWithRefunds).

CREATE OR REPLACE FUNCTION public.refund_generation_failed(
  p_user_id UUID,
  p_amount INTEGER,
  p_track_id UUID,
  p_description TEXT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance INTEGER;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.profiles
  SET balance = balance + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_new_balance;

  IF v_new_balance IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_id;
  END IF;

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    balance_after,
    type,
    description,
    reference_id,
    reference_type
  )
  VALUES (
    p_user_id,
    p_amount,
    v_new_balance,
    'refund',
    p_description,
    p_track_id,
    'track'
  );

  RETURN v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refund_generation_failed(UUID, INTEGER, UUID, TEXT) TO service_role;

COMMENT ON FUNCTION public.refund_generation_failed IS 'Атомарный возврат средств при ошибке генерации трека. Используется suno-callback.';
