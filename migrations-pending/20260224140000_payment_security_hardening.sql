-- ============================================================
-- Payment Security Hardening
-- Атомарное зачисление/списание баланса, защита от дублей
-- ============================================================

-- 1. Атомарная функция зачисления баланса при успешной оплате
-- Использует FOR UPDATE для блокировки строки + проверку idempotency
CREATE OR REPLACE FUNCTION public.process_payment_completion(
  p_payment_id UUID,
  p_expected_amount INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment RECORD;
  v_new_balance INTEGER;
BEGIN
  -- Атомарно захватываем платёж с блокировкой строки
  SELECT * INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_found');
  END IF;

  -- Idempotency: если уже обработан — возвращаем OK без повторного зачисления
  IF v_payment.status = 'completed' THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END IF;

  -- Защита: платёж должен быть в статусе pending
  IF v_payment.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_status', 'current_status', v_payment.status);
  END IF;

  -- Кросс-валидация суммы (если передана от платёжной системы)
  IF p_expected_amount IS NOT NULL AND p_expected_amount != v_payment.amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'amount_mismatch',
      'expected', p_expected_amount, 'actual', v_payment.amount);
  END IF;

  -- Обновляем статус платежа
  UPDATE public.payments
  SET status = 'completed', updated_at = now()
  WHERE id = p_payment_id;

  -- Атомарно зачисляем баланс
  UPDATE public.profiles
  SET balance = balance + v_payment.amount
  WHERE user_id = v_payment.user_id
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'profile_not_found');
  END IF;

  -- Логируем транзакцию
  INSERT INTO public.balance_transactions (
    user_id, amount, balance_after, type, description, reference_id, reference_type
  ) VALUES (
    v_payment.user_id,
    v_payment.amount,
    v_new_balance,
    'topup',
    v_payment.description,
    v_payment.id,
    'payment'
  );

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_payment.user_id,
    'amount', v_payment.amount,
    'new_balance', v_new_balance
  );
END;
$$;

-- 2. Атомарная функция возврата средств
CREATE OR REPLACE FUNCTION public.process_payment_refund(
  p_payment_id UUID,
  p_refund_amount INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment RECORD;
  v_refund_amount INTEGER;
  v_new_balance INTEGER;
BEGIN
  SELECT * INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_found');
  END IF;

  IF v_payment.status = 'refunded' THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END IF;

  IF v_payment.status != 'completed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_completed');
  END IF;

  v_refund_amount := COALESCE(p_refund_amount, v_payment.amount);

  UPDATE public.payments
  SET status = 'refunded', updated_at = now()
  WHERE id = p_payment_id;

  -- Атомарно списываем баланс (не ниже нуля)
  UPDATE public.profiles
  SET balance = GREATEST(0, balance - v_refund_amount)
  WHERE user_id = v_payment.user_id
  RETURNING balance INTO v_new_balance;

  IF FOUND THEN
    INSERT INTO public.balance_transactions (
      user_id, amount, balance_after, type, description, reference_id, reference_type
    ) VALUES (
      v_payment.user_id,
      -v_refund_amount,
      v_new_balance,
      'refund',
      COALESCE('Возврат средств: ' || v_payment.description, 'Возврат средств: платёж #' || p_payment_id::text),
      v_payment.id,
      'payment'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_payment.user_id,
    'refund_amount', v_refund_amount,
    'new_balance', v_new_balance
  );
END;
$$;

-- 3. UNIQUE constraint на external_id + payment_system (защита от дублей)
-- Используем partial index, т.к. external_id может быть NULL для pending платежей
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_external_id_system_unique
ON public.payments (external_id, payment_system)
WHERE external_id IS NOT NULL;

-- 4. CHECK constraint на сумму
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.check_constraints
    WHERE constraint_name = 'payments_amount_range'
  ) THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_amount_range
    CHECK (amount >= 1 AND amount <= 150000);
  END IF;
END $$;

-- 5. Индекс для быстрого поиска по external_id (используется в callbacks)
CREATE INDEX IF NOT EXISTS idx_payments_external_id_lookup
ON public.payments (external_id, payment_system)
WHERE status = 'pending';
