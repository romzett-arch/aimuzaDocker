-- Fix admin_reject_purchase:
-- 1. Extend SELECT to include is_exclusive from store_items
-- 2. Restore exclusive lyrics_items to is_for_sale=true on reject
--    (trigger sync_lyrics_to_store_items will auto-restore store_items.is_active)
-- 3. Update seller notification text for exclusive lyrics

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

  -- Restore exclusive lyrics back to sale (trigger sync_lyrics_to_store_items
  -- will automatically set store_items.is_active = true via ON CONFLICT DO UPDATE)
  IF v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false) THEN
    UPDATE public.lyrics_items
    SET is_for_sale = true, is_active = true
    WHERE id = v_purchase.source_id;
  END IF;

  -- Notify buyer
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

  -- Notify seller
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_purchase.seller_id,
    'deal_rejected',
    'Сделка отклонена',
    v_item_title || ' — ' ||
      CASE
        WHEN v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false)
        THEN COALESCE(NULLIF(p_admin_notes, ''), 'Администрация отклонила сделку') || '. Текст снова доступен для продажи.'
        ELSE COALESCE(NULLIF(p_admin_notes, ''), 'Администрация отклонила сделку')
      END,
    auth.uid(),
    'item_purchase',
    p_purchase_id
  );
END;
$$;
