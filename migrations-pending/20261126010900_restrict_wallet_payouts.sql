-- The wallet still pays for services. Only verified seller proceeds can fund payouts.
CREATE TABLE promotions.seller_cash (
  user_id uuid PRIMARY KEY,
  available integer NOT NULL CHECK (available >= 0)
);

-- Block concurrent ledger writers while deriving opening balances. Service
-- refunds and top-ups never manufacture seller proceeds, even on old accounts.
LOCK TABLE public.profiles IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.balance_transactions IN SHARE ROW EXCLUSIVE MODE;
DO $$
DECLARE entry record;
DECLARE previous_user uuid;
DECLARE available integer := 0;
BEGIN
  FOR entry IN
    SELECT user_id, type, amount, balance_after
    FROM public.balance_transactions
    ORDER BY user_id, created_at, id
  LOOP
    IF previous_user IS DISTINCT FROM entry.user_id THEN
      previous_user := entry.user_id;
      available := 0;
    END IF;
    IF entry.type = 'sale_income' AND entry.amount > 0 THEN
      available := available + entry.amount;
    ELSIF entry.type = 'payout_hold' AND entry.amount < 0 THEN
      available := greatest(0, available + entry.amount);
    END IF;
    available := least(available, greatest(0, coalesce(entry.balance_after, 0)));
    INSERT INTO promotions.seller_cash(user_id, available)
    VALUES (entry.user_id, available)
    ON CONFLICT (user_id) DO UPDATE SET available = EXCLUDED.available;
  END LOOP;
  UPDATE promotions.seller_cash c SET available = least(c.available, greatest(p.balance, 0))
  FROM public.profiles p WHERE p.user_id = c.user_id;
END;
$$;

CREATE FUNCTION promotions.limit_seller_cash()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  UPDATE promotions.seller_cash SET available = greatest(NEW.balance, 0)
  WHERE user_id = NEW.user_id AND available > greatest(NEW.balance, 0);
  RETURN NEW;
END;
$$;
CREATE TRIGGER limit_seller_cash AFTER UPDATE OF balance ON public.profiles
FOR EACH ROW WHEN (NEW.balance < OLD.balance) EXECUTE FUNCTION promotions.limit_seller_cash();

CREATE FUNCTION promotions.credit_seller_cash()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE wallet_balance integer;
BEGIN
  SELECT balance INTO wallet_balance FROM public.profiles WHERE user_id = NEW.user_id FOR UPDATE;
  IF NOT FOUND OR wallet_balance <= 0 THEN RETURN NEW; END IF;
  INSERT INTO promotions.seller_cash(user_id, available)
  VALUES (NEW.user_id, least(NEW.amount, wallet_balance))
  ON CONFLICT (user_id) DO UPDATE
  SET available = least(promotions.seller_cash.available + EXCLUDED.available, wallet_balance);
  RETURN NEW;
END;
$$;
CREATE TRIGGER credit_seller_cash AFTER INSERT ON public.balance_transactions
FOR EACH ROW WHEN (NEW.amount > 0 AND (NEW.type = 'sale_income' OR
  (NEW.type = 'payout_release' AND NEW.metadata @> '{"verified_seller_proceeds": true}')))
EXECUTE FUNCTION promotions.credit_seller_cash();

CREATE FUNCTION public.get_my_payout_available()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT coalesce((SELECT least(c.available, greatest(p.balance, 0))
    FROM promotions.seller_cash c JOIN public.profiles p ON p.user_id = c.user_id
    WHERE c.user_id = auth.uid()), 0)
$$;
REVOKE ALL ON FUNCTION public.get_my_payout_available() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_payout_available() TO authenticated;

CREATE OR REPLACE FUNCTION public.request_seller_payout(
  p_amount numeric, p_payment_method text, p_payment_details text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  member uuid := auth.uid();
  minimum numeric;
  wallet_balance integer;
  payout_id uuid;
BEGIN
  IF member IS NULL THEN RAISE EXCEPTION 'access_denied'; END IF;
  SELECT nullif(value, '')::numeric INTO minimum FROM public.settings WHERE key = 'min_payout_amount';
  minimum := coalesce(minimum, 100);
  IF p_amount IS NULL OR p_amount::text IN ('NaN', 'Infinity', '-Infinity')
    OR p_amount > 2147483647 OR p_amount <> trunc(p_amount) OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_amount');
  END IF;
  IF p_amount < minimum THEN
    RETURN jsonb_build_object('success', false, 'error', 'below_minimum', 'minimum', minimum);
  END IF;
  IF nullif(trim(p_payment_method), '') IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'payment_method_required');
  END IF;
  SELECT balance INTO wallet_balance FROM public.profiles WHERE user_id = member FOR UPDATE;
  IF coalesce(wallet_balance, 0) < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance');
  END IF;
  UPDATE promotions.seller_cash SET available = available - p_amount
  WHERE user_id = member AND available >= p_amount;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_withdrawable_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = member;
  INSERT INTO public.payout_requests(seller_id, amount, payment_method, payment_details, status)
  VALUES(member, p_amount, p_payment_method, p_payment_details, 'pending') RETURNING id INTO payout_id;
  INSERT INTO public.balance_transactions(user_id, amount, balance_before, balance_after,
    type, description, reference_id, reference_type, metadata)
  VALUES(member, -p_amount, wallet_balance, wallet_balance - p_amount, 'payout_hold',
    'Резерв на выплату', payout_id, 'payout_request',
    '{"financial_effect": "seller_liability_settlement", "verified_seller_proceeds": true}');
  RETURN jsonb_build_object('success', true, 'request_id', payout_id, 'new_balance', wallet_balance - p_amount);
END;
$$;

CREATE OR REPLACE FUNCTION public.process_payout_request(
  p_request_id uuid, p_status text, p_notes text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  actor uuid := auth.uid();
  payout public.payout_requests%ROWTYPE;
  wallet_balance integer;
  verified boolean;
BEGIN
  IF actor IS NULL OR NOT public.is_admin(actor) THEN RAISE EXCEPTION 'access_denied'; END IF;
  IF p_status NOT IN ('processing', 'completed', 'rejected', 'failed') OR p_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_status');
  END IF;
  SELECT * INTO payout FROM public.payout_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'request_not_found'); END IF;
  IF payout.status = p_status THEN RETURN jsonb_build_object('success', true, 'already_processed', true); END IF;
  IF payout.status NOT IN ('pending', 'processing') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_transition');
  END IF;
  SELECT EXISTS (SELECT FROM public.balance_transactions
    WHERE user_id = payout.seller_id AND reference_id = payout.id AND type = 'payout_hold'
      AND amount = -payout.amount AND metadata @> '{"verified_seller_proceeds": true}') INTO verified;
  IF NOT verified AND p_status IN ('processing', 'completed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'legacy_payout_requires_new_request');
  END IF;

  IF p_status IN ('rejected', 'failed') THEN
    UPDATE public.profiles SET balance = balance + payout.amount WHERE user_id = payout.seller_id
    RETURNING balance INTO wallet_balance;
    INSERT INTO public.balance_transactions(user_id, amount, balance_before, balance_after,
      type, description, reference_id, reference_type, metadata)
    VALUES(payout.seller_id, payout.amount, wallet_balance - payout.amount, wallet_balance,
      'payout_release', 'Возврат резерва выплаты', payout.id, 'payout_request',
      jsonb_build_object('financial_effect', 'seller_liability_restore', 'verified_seller_proceeds', verified));
  END IF;
  UPDATE public.payout_requests SET status = p_status, notes = p_notes, processed_by = actor,
    processed_at = CASE WHEN p_status IN ('completed', 'rejected', 'failed') THEN now() ELSE NULL END
  WHERE id = p_request_id;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$;

REVOKE ALL ON FUNCTION promotions.limit_seller_cash(), promotions.credit_seller_cash()
  FROM PUBLIC, anon, authenticated, service_role;
