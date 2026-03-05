-- Escrow: admin must approve deals before seller receives funds
-- Buyer gets content immediately; seller gets money only after admin approval

-- 1a. Extend item_purchases
ALTER TABLE public.item_purchases
  ADD COLUMN IF NOT EXISTS admin_status text DEFAULT 'pending_review',
  ADD COLUMN IF NOT EXISTS reviewed_by uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_notes text,
  ADD COLUMN IF NOT EXISTS blockchain_tx_id text,
  ADD COLUMN IF NOT EXISTS copyright_status text DEFAULT 'none';

-- 1b. Backfill existing records (money already sent to sellers)
UPDATE public.item_purchases SET admin_status = 'approved' WHERE admin_status IS NULL OR admin_status = 'pending_review';
UPDATE public.seller_earnings SET status = 'available' WHERE status = 'pending';

-- 1c. Rewrite process_store_item_purchase (escrow: no seller balance update)
DROP FUNCTION IF EXISTS public.process_store_item_purchase(UUID, UUID);

CREATE OR REPLACE FUNCTION public.process_store_item_purchase(
  p_buyer_id UUID,
  p_store_item_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
  v_buyer_balance_before INTEGER;
  v_buyer_balance INTEGER;
  v_admin_id UUID;
BEGIN
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_item FROM public.store_items
  WHERE id = p_store_item_id AND is_active = true;

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Item not found or not available';
  END IF;

  IF v_item.seller_id = p_buyer_id THEN
    RAISE EXCEPTION 'Cannot purchase your own item';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.item_purchases
    WHERE store_item_id = p_store_item_id AND buyer_id = p_buyer_id
  ) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;

  v_platform_fee := ROUND(v_item.price * 0.1);
  v_net_amount := v_item.price - v_platform_fee;

  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = p_buyer_id FOR UPDATE;
  IF v_buyer_balance_before < v_item.price THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  UPDATE public.profiles SET balance = balance - v_item.price
  WHERE user_id = p_buyer_id
  RETURNING balance INTO v_buyer_balance;

  INSERT INTO public.item_purchases (
    buyer_id, seller_id, store_item_id, item_type, source_id,
    price, license_type, platform_fee, net_amount, admin_status
  )
  VALUES (
    p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type,
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount,
    'pending_review'
  )
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (user_id, amount, source_type, source_id, platform_fee, net_amount, status)
  VALUES (v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id, v_platform_fee, v_net_amount, 'pending');

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase',
    'Покупка: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

  -- NO seller balance_transaction here - will be created on admin approval

  IF v_item.is_exclusive THEN
    UPDATE public.store_items SET is_active = false WHERE id = p_store_item_id;

    IF v_item.item_type = 'prompt' THEN
      UPDATE public.user_prompts SET is_public = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'lyrics' THEN
      UPDATE public.lyrics_items SET is_active = false, is_for_sale = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'beat' THEN
      UPDATE public.store_beats SET is_active = false WHERE id = v_item.source_id;
    END IF;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_item.seller_id,
    'item_sold',
    'Продажа: ' || v_item.title,
    'Ваш товар куплен за ' || v_item.price || ' ₽. Ожидает подтверждения администрации.',
    p_buyer_id,
    'item_purchase',
    v_purchase_id
  );

  FOR v_admin_id IN SELECT user_id FROM public.user_roles WHERE role IN ('admin', 'super_admin')
  LOOP
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_admin_id,
      'deal_pending_review',
      'Новая сделка на рассмотрении',
      v_item.title || ' — ' || v_item.price || ' ₽',
      p_buyer_id,
      'item_purchase',
      v_purchase_id
    );
  END LOOP;

  RETURN v_purchase_id;
END;
$$;

-- 1d. admin_approve_purchase
CREATE OR REPLACE FUNCTION public.admin_approve_purchase(
  p_purchase_id UUID,
  p_admin_notes text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase RECORD;
  v_seller_balance_before INTEGER;
  v_seller_balance INTEGER;
  v_item_title TEXT;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.*, si.title AS item_title
  INTO v_purchase
  FROM public.item_purchases ip
  JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RAISE EXCEPTION 'Purchase not found';
  END IF;

  IF v_purchase.admin_status != 'pending_review' THEN
    RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status;
  END IF;

  v_item_title := v_purchase.item_title;

  SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_purchase.seller_id FOR UPDATE;

  UPDATE public.profiles SET balance = balance + v_purchase.net_amount
  WHERE user_id = v_purchase.seller_id
  RETURNING balance INTO v_seller_balance;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    v_purchase.seller_id, v_purchase.net_amount, v_seller_balance_before, v_seller_balance,
    'sale_income',
    'Продажа (одобрено): ' || v_item_title,
    v_purchase.store_item_id, 'store_item'
  );

  UPDATE public.item_purchases
  SET admin_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
  WHERE id = p_purchase_id;

  UPDATE public.seller_earnings
  SET status = 'available'
  WHERE source_id = p_purchase_id;

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.seller_id,
    'deal_approved',
    'Сделка одобрена',
    v_item_title || ' — ' || v_purchase.net_amount || ' ₽ зачислено',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;

-- 1e. admin_reject_purchase
CREATE OR REPLACE FUNCTION public.admin_reject_purchase(
  p_purchase_id UUID,
  p_admin_notes text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase RECORD;
  v_buyer_balance_before INTEGER;
  v_buyer_balance INTEGER;
  v_item_title TEXT;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.*, si.title AS item_title
  INTO v_purchase
  FROM public.item_purchases ip
  JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RAISE EXCEPTION 'Purchase not found';
  END IF;

  IF v_purchase.admin_status != 'pending_review' THEN
    RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status;
  END IF;

  v_item_title := v_purchase.item_title;

  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = v_purchase.buyer_id FOR UPDATE;

  UPDATE public.profiles SET balance = balance + v_purchase.price
  WHERE user_id = v_purchase.buyer_id
  RETURNING balance INTO v_buyer_balance;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    v_purchase.buyer_id, v_purchase.price, v_buyer_balance_before, v_buyer_balance,
    'refund',
    'Возврат: ' || v_item_title,
    v_purchase.store_item_id, 'store_item'
  );

  UPDATE public.item_purchases
  SET admin_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
  WHERE id = p_purchase_id;

  UPDATE public.seller_earnings
  SET status = 'rejected'
  WHERE source_id = p_purchase_id;

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.buyer_id,
    'deal_rejected',
    'Сделка отклонена',
    v_item_title || ' — ' || v_purchase.price || ' ₽ возвращено',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.seller_id,
    'deal_rejected',
    'Сделка отклонена',
    v_item_title || ' — ' || COALESCE(p_admin_notes, 'Администрация отклонила сделку'),
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;
