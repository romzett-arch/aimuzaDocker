-- Transfer lyrics ownership to buyer when admin approves exclusive lyrics purchase
-- Seller keeps deal in sales history (item_purchases); buyer gets lyrics in "Мои тексты"

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

  SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
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

  -- Transfer lyrics ownership to buyer (exclusive only)
  IF v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false) THEN
    UPDATE public.lyrics_items
    SET user_id = v_purchase.buyer_id, is_for_sale = false, is_active = false
    WHERE id = v_purchase.source_id;
  END IF;

  -- Notify seller
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

  -- Notify buyer (especially for lyrics — now in "Мои тексты")
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.buyer_id,
    'deal_approved',
    'Покупка одобрена',
    v_item_title || ' — теперь в разделе «Мои тексты»',
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;
