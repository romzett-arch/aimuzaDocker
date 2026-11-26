-- An account can spend its full wallet on AIMUZA services. Payments to
-- third-party sellers must be funded by cash-backed wallet movements.
CREATE TABLE promotions.marketplace_funds (
  user_id uuid PRIMARY KEY,
  available integer NOT NULL CHECK (available >= 0),
  before_clamp integer,
  clamped_in bigint,
  clamped_wallet_balance integer
);

LOCK TABLE public.profiles IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.balance_transactions IN SHARE ROW EXCLUSIVE MODE;

DO $$
DECLARE entry record;
DECLARE member uuid;
DECLARE available integer := 0;
BEGIN
  FOR entry IN SELECT user_id, type, amount, balance_after, reference_type
      FROM public.balance_transactions ORDER BY user_id, created_at, id
  LOOP
    IF member IS DISTINCT FROM entry.user_id THEN
      member := entry.user_id;
      available := 0;
    END IF;
    IF entry.amount > 0 AND (entry.type IN ('topup', 'sale_income')
      OR (entry.type = 'refund' AND entry.reference_type = 'store_item')) THEN
      available := available + entry.amount;
    ELSIF entry.amount < 0 AND (entry.type IN ('payout_hold', 'item_purchase')
      OR (entry.type = 'refund' AND entry.reference_type = 'payment')) THEN
      available := greatest(0, available + entry.amount);
    END IF;
    available := least(available, greatest(0, coalesce(entry.balance_after, 0)));
    INSERT INTO promotions.marketplace_funds(user_id, available) VALUES (entry.user_id, available)
    ON CONFLICT(user_id) DO UPDATE SET available = EXCLUDED.available;
  END LOOP;
  UPDATE promotions.marketplace_funds f SET available = least(f.available, greatest(p.balance, 0))
  FROM public.profiles p WHERE p.user_id = f.user_id;
END;
$$;

CREATE FUNCTION promotions.limit_marketplace_funds()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  UPDATE promotions.marketplace_funds
  SET before_clamp = available, clamped_in = txid_current(), clamped_wallet_balance = NEW.balance,
    available = least(available, greatest(NEW.balance, 0))
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER limit_marketplace_funds AFTER UPDATE OF balance ON public.profiles
FOR EACH ROW WHEN (NEW.balance < OLD.balance) EXECUTE FUNCTION promotions.limit_marketplace_funds();

CREATE FUNCTION promotions.credit_marketplace_funds()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE wallet integer;
BEGIN
  SELECT balance INTO wallet FROM public.profiles WHERE user_id = NEW.user_id FOR UPDATE;
  IF NOT FOUND OR wallet <= 0 THEN RETURN NEW; END IF;
  INSERT INTO promotions.marketplace_funds(user_id, available)
  VALUES (NEW.user_id, least(NEW.amount, wallet))
  ON CONFLICT (user_id) DO UPDATE
  SET available = least(promotions.marketplace_funds.available + EXCLUDED.available, wallet);
  RETURN NEW;
END;
$$;
CREATE TRIGGER credit_marketplace_funds AFTER INSERT ON public.balance_transactions
FOR EACH ROW WHEN (NEW.amount > 0 AND (
  NEW.type IN ('topup', 'sale_income')
  OR (NEW.type = 'refund' AND NEW.reference_type = 'store_item')
  OR (NEW.type = 'payout_release' AND NEW.metadata @> '{"verified_seller_proceeds": true}')))
EXECUTE FUNCTION promotions.credit_marketplace_funds();

ALTER FUNCTION public.process_store_item_purchase(uuid,uuid) RENAME TO process_cash_backed_store_purchase;
REVOKE ALL ON FUNCTION public.process_cash_backed_store_purchase(uuid,uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.process_store_item_purchase(p_buyer_id uuid, p_store_item_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE price integer;
BEGIN
  IF auth.uid() IS NULL OR p_buyer_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;
  SELECT item.price INTO price FROM public.store_items item
  WHERE item.id = p_store_item_id AND item.is_active IS TRUE AND item.item_type IN ('prompt','lyrics') FOR UPDATE;
  IF price > 0 THEN
    PERFORM FROM public.profiles WHERE user_id = p_buyer_id FOR UPDATE;
    UPDATE promotions.marketplace_funds SET available = available - price
    WHERE user_id = p_buyer_id AND available >= price;
    IF NOT FOUND THEN RAISE EXCEPTION 'insufficient_marketplace_funds'; END IF;
  END IF;
  RETURN public.process_cash_backed_store_purchase(p_buyer_id, p_store_item_id);
END;
$$;
REVOKE ALL ON FUNCTION public.process_store_item_purchase(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_store_item_purchase(uuid,uuid) TO authenticated;

-- Payout and payment-refund holds leave the cash-backed part explicitly.
CREATE FUNCTION promotions.reduce_marketplace_transfer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  UPDATE promotions.marketplace_funds SET available = least(available, greatest(0,
    (CASE WHEN clamped_in = txid_current() AND clamped_wallet_balance = NEW.balance_after
      THEN before_clamp ELSE available END) + NEW.amount)), clamped_in = NULL
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER reduce_marketplace_transfer AFTER INSERT ON public.balance_transactions
FOR EACH ROW WHEN (NEW.amount < 0 AND (NEW.type = 'payout_hold' OR
  (NEW.type = 'refund' AND NEW.reference_type = 'payment')))
EXECUTE FUNCTION promotions.reduce_marketplace_transfer();

REVOKE ALL ON FUNCTION promotions.limit_marketplace_funds(), promotions.credit_marketplace_funds(),
  promotions.reduce_marketplace_transfer() FROM PUBLIC, anon, authenticated, service_role;
