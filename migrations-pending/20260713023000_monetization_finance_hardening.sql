-- Monetization finance hardening: secure refunds/payouts and separate cash from wallet turnover.

ALTER TABLE public.payout_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.balance_transactions ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payout_requests_amount_positive') THEN
    ALTER TABLE public.payout_requests ADD CONSTRAINT payout_requests_amount_positive CHECK (amount > 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payout_requests_status_valid') THEN
    ALTER TABLE public.payout_requests ADD CONSTRAINT payout_requests_status_valid
      CHECK (status IN ('pending', 'processing', 'completed', 'rejected', 'failed'));
  END IF;
END $$;

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
  v_role TEXT := COALESCE(current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role <> 'service_role' AND (auth.uid() IS NULL OR NOT public.is_admin(auth.uid())) THEN
    RAISE EXCEPTION 'access_denied';
  END IF;

  SELECT * INTO v_payment FROM public.payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'payment_not_found'); END IF;
  IF v_payment.status = 'refunded' THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true, 'gateway_refund_required', false);
  END IF;
  IF v_payment.status NOT IN ('completed', 'succeeded') THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_not_completed');
  END IF;

  v_refund_amount := COALESCE(p_refund_amount, v_payment.amount);
  IF v_refund_amount <= 0 OR v_refund_amount > v_payment.amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_refund_amount');
  END IF;
  IF v_refund_amount <> v_payment.amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'partial_refund_not_supported');
  END IF;

  UPDATE public.payments SET status = 'refunded', updated_at = now() WHERE id = p_payment_id;
  UPDATE public.profiles
     SET balance = balance - v_refund_amount
   WHERE user_id = v_payment.user_id
   RETURNING balance INTO v_new_balance;

  IF FOUND THEN
    INSERT INTO public.balance_transactions
      (user_id, amount, balance_after, type, description, reference_id, reference_type, metadata)
    VALUES
      (v_payment.user_id, -v_refund_amount, v_new_balance, 'refund',
       COALESCE('Возврат средств: ' || v_payment.description, 'Возврат средств: платёж #' || p_payment_id::text),
       v_payment.id, 'payment', jsonb_build_object('financial_effect', 'cash_refund'));
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'user_id', v_payment.user_id, 'refund_amount', v_refund_amount,
    'new_balance', v_new_balance,
    'gateway_refund_required', v_role <> 'service_role' AND v_payment.payment_system IN ('robokassa', 'yookassa')
  );
END;
$$;
REVOKE ALL ON FUNCTION public.process_payment_refund(UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_payment_refund(UUID, INTEGER) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.request_seller_payout(
  p_amount NUMERIC,
  p_payment_method TEXT,
  p_payment_details TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_min NUMERIC;
  v_balance INTEGER;
  v_request public.payout_requests%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'access_denied'; END IF;
  SELECT COALESCE(NULLIF(value, '')::NUMERIC, 100) INTO v_min FROM public.settings WHERE key = 'min_payout_amount';
  v_min := COALESCE(v_min, 100);
  IF p_amount < v_min THEN RETURN jsonb_build_object('success', false, 'error', 'below_minimum', 'minimum', v_min); END IF;
  IF NULLIF(trim(p_payment_method), '') IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'payment_method_required'); END IF;

  UPDATE public.profiles SET balance = balance - p_amount
   WHERE user_id = v_user AND balance >= p_amount
   RETURNING balance INTO v_balance;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance'); END IF;

  INSERT INTO public.payout_requests(seller_id, amount, payment_method, payment_details, status)
  VALUES(v_user, p_amount, p_payment_method, p_payment_details, 'pending') RETURNING * INTO v_request;
  INSERT INTO public.balance_transactions(user_id, amount, balance_after, type, description, reference_id, reference_type, metadata)
  VALUES(v_user, -p_amount, v_balance, 'payout_hold', 'Резерв на выплату', v_request.id, 'payout_request',
    jsonb_build_object('financial_effect', 'seller_liability_settlement'));
  RETURN jsonb_build_object('success', true, 'request_id', v_request.id, 'new_balance', v_balance);
END;
$$;
REVOKE ALL ON FUNCTION public.request_seller_payout(NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_seller_payout(NUMERIC, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_payout_request(p_request_id UUID, p_status TEXT, p_notes TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_request public.payout_requests%ROWTYPE;
  v_balance INTEGER;
BEGIN
  IF v_admin IS NULL OR NOT public.is_admin(v_admin) THEN RAISE EXCEPTION 'access_denied'; END IF;
  IF p_status NOT IN ('processing', 'completed', 'rejected', 'failed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_status');
  END IF;
  SELECT * INTO v_request FROM public.payout_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'request_not_found'); END IF;
  IF v_request.status = p_status THEN RETURN jsonb_build_object('success', true, 'already_processed', true); END IF;
  IF v_request.status NOT IN ('pending', 'processing') THEN RETURN jsonb_build_object('success', false, 'error', 'invalid_transition'); END IF;

  IF p_status IN ('rejected', 'failed') THEN
    UPDATE public.profiles SET balance = balance + v_request.amount WHERE user_id = v_request.seller_id RETURNING balance INTO v_balance;
    INSERT INTO public.balance_transactions(user_id, amount, balance_after, type, description, reference_id, reference_type, metadata)
    VALUES(v_request.seller_id, v_request.amount, v_balance, 'payout_release', 'Возврат резерва выплаты',
      v_request.id, 'payout_request', jsonb_build_object('financial_effect', 'seller_liability_restore'));
  END IF;
  UPDATE public.payout_requests SET status = p_status, notes = p_notes, processed_by = v_admin,
    processed_at = CASE WHEN p_status IN ('completed', 'rejected', 'failed') THEN now() ELSE NULL END
  WHERE id = p_request_id;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$;
REVOKE ALL ON FUNCTION public.process_payout_request(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_payout_request(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_admin_monetization_dashboard()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller UUID := auth.uid();
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN RAISE EXCEPTION 'access_denied'; END IF;
  RETURN (
    WITH cash AS (
      SELECT
        COALESCE(SUM(amount) FILTER (WHERE status IN ('completed','succeeded') AND amount > 0), 0)::BIGINT cash_inflow,
        COALESCE(SUM(amount) FILTER (WHERE status = 'refunded' AND amount > 0), 0)::BIGINT cash_refunds,
        COUNT(*) FILTER (WHERE status IN ('completed','succeeded') AND amount > 0)::BIGINT topup_count
      FROM public.payments WHERE payment_system IN ('robokassa','yookassa')
    ),
    wallet AS (
      SELECT
        COALESCE(SUM(ABS(amount)) FILTER (WHERE amount < 0 AND type NOT IN ('refund','payout_hold')), 0)::BIGINT internal_consumption,
        COUNT(*) FILTER (WHERE amount < 0 AND type NOT IN ('refund','payout_hold'))::BIGINT paid_operations
      FROM public.balance_transactions
    ),
    marketplace AS (
      SELECT COALESCE(SUM(platform_fee) FILTER (WHERE status <> 'refunded'), 0)::BIGINT fee,
             COALESCE(SUM(net_amount) FILTER (WHERE status IN ('pending','available')), 0)::BIGINT seller_liability
      FROM public.seller_earnings
    ),
    costs AS (
      SELECT COALESCE(SUM(cost_rub) FILTER (WHERE status='completed'),0)::NUMERIC generation_cost FROM public.generation_logs
    )
    SELECT jsonb_build_object(
      'cashInflow', c.cash_inflow, 'cashRefunds', c.cash_refunds, 'netCashRevenue', c.cash_inflow-c.cash_refunds,
      'topupRevenue', c.cash_inflow, 'topupCount', c.topup_count,
      'internalConsumption', w.internal_consumption, 'platformRevenue', w.internal_consumption + m.fee,
      'marketplaceFeeRevenue', m.fee, 'sellerLiability', m.seller_liability,
      'paidOperations', w.paid_operations, 'actualGenerationCost', co.generation_cost,
      'addonStats', '[]'::jsonb
    ) FROM cash c CROSS JOIN wallet w CROSS JOIN marketplace m CROSS JOIN costs co
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_admin_monetization_dashboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_monetization_dashboard() TO authenticated;
