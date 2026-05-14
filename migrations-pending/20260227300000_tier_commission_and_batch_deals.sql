-- 1. Fix hardcoded 10% commission → use seller's tier marketplace_commission
-- 2. Add batch_approve_purchases / batch_reject_purchases for admin efficiency

-- ============================================================
-- 1. Rewrite process_store_item_purchase with tier-based commission
-- ============================================================
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
  v_seller_balance_before INTEGER;
  v_seller_balance INTEGER;
  v_admin_id UUID;
  v_is_escrow BOOLEAN;
  v_commission_rate NUMERIC;
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

  -- Lookup seller's tier commission rate (fallback to 10% default)
  SELECT COALESCE(rt.marketplace_commission, 0.10)
  INTO v_commission_rate
  FROM public.forum_user_stats fus
  JOIN public.reputation_tiers rt ON rt.key = fus.tier
  WHERE fus.user_id = v_item.seller_id;

  -- If seller has no tier record, use default 10%
  IF v_commission_rate IS NULL THEN
    v_commission_rate := 0.10;
  END IF;

  v_platform_fee := GREATEST(1, ROUND(v_item.price * v_commission_rate));
  v_net_amount := v_item.price - v_platform_fee;

  -- Escrow only for lyrics
  v_is_escrow := (v_item.item_type = 'lyrics');

  -- Deduct buyer balance
  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = p_buyer_id FOR UPDATE;
  IF v_buyer_balance_before < v_item.price THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  UPDATE public.profiles SET balance = balance - v_item.price
  WHERE user_id = p_buyer_id
  RETURNING balance INTO v_buyer_balance;

  -- Create purchase record
  INSERT INTO public.item_purchases (
    buyer_id, seller_id, store_item_id, item_type, source_id,
    price, license_type, platform_fee, net_amount, admin_status
  )
  VALUES (
    p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type,
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending_review' ELSE 'approved' END
  )
  RETURNING id INTO v_purchase_id;

  -- Create seller earning
  INSERT INTO public.seller_earnings (user_id, amount, source_type, source_id, platform_fee, net_amount, status)
  VALUES (
    v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id, v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending' ELSE 'available' END
  );

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;

  -- Buyer balance transaction (always)
  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase',
    'Покупка: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

  IF v_is_escrow THEN
    -- LYRICS: no seller balance update yet; notify admins
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_item.seller_id,
      'item_sold',
      'Продажа: ' || v_item.title,
      'Ваш текст куплен за ' || v_item.price || ' ₽. Ожидает подтверждения администрации.',
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
        v_item.title || ' — ' || v_item.price || ' ₽ (текст)',
        p_buyer_id,
        'item_purchase',
        v_purchase_id
      );
    END LOOP;
  ELSE
    -- PROMPT/BEAT: instant sale — credit seller immediately
    SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_item.seller_id FOR UPDATE;

    UPDATE public.profiles SET balance = balance + v_net_amount
    WHERE user_id = v_item.seller_id
    RETURNING balance INTO v_seller_balance;

    INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
    VALUES (
      v_item.seller_id, v_net_amount, v_seller_balance_before, v_seller_balance,
      'sale_income',
      'Продажа: ' || v_item.title,
      p_store_item_id, 'store_item'
    );

    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_item.seller_id,
      'item_sold',
      'Продажа: ' || v_item.title,
      'Ваш промпт куплен за ' || v_item.price || ' ₽. Средства зачислены.',
      p_buyer_id,
      'item_purchase',
      v_purchase_id
    );
  END IF;

  -- Handle exclusive items
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

  RETURN v_purchase_id;
END;
$$;

-- ============================================================
-- 2. Batch approve purchases (admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.batch_approve_purchases(
  p_purchase_ids UUID[],
  p_admin_notes text DEFAULT ''
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase RECORD;
  v_seller_balance_before INTEGER;
  v_seller_balance INTEGER;
  v_approved_count INTEGER := 0;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  FOR v_purchase IN
    SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
    FROM public.item_purchases ip
    JOIN public.store_items si ON si.id = ip.store_item_id
    WHERE ip.id = ANY(p_purchase_ids)
      AND ip.admin_status = 'pending_review'
    ORDER BY ip.created_at
  LOOP
    -- Credit seller
    SELECT balance INTO v_seller_balance_before
    FROM public.profiles WHERE user_id = v_purchase.seller_id FOR UPDATE;

    UPDATE public.profiles SET balance = balance + v_purchase.net_amount
    WHERE user_id = v_purchase.seller_id
    RETURNING balance INTO v_seller_balance;

    INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
    VALUES (
      v_purchase.seller_id, v_purchase.net_amount, v_seller_balance_before, v_seller_balance,
      'sale_income',
      'Продажа (одобрено): ' || v_purchase.item_title,
      v_purchase.store_item_id, 'store_item'
    );

    -- Update purchase status
    UPDATE public.item_purchases
    SET admin_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
    WHERE id = v_purchase.id;

    UPDATE public.seller_earnings
    SET status = 'available'
    WHERE source_id = v_purchase.id;

    -- Transfer lyrics ownership (exclusive only)
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
      v_purchase.item_title || ' — ' || v_purchase.net_amount || ' ₽ зачислено',
      auth.uid(),
      'item_purchase',
      v_purchase.id
    );

    -- Notify buyer
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_purchase.buyer_id,
      'deal_approved',
      'Покупка одобрена',
      v_purchase.item_title || ' — теперь в разделе «Мои тексты»',
      auth.uid(),
      'item_purchase',
      v_purchase.id
    );

    v_approved_count := v_approved_count + 1;
  END LOOP;

  RETURN v_approved_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.batch_approve_purchases(UUID[], text) TO authenticated;

-- ============================================================
-- 3. Batch reject purchases (admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.batch_reject_purchases(
  p_purchase_ids UUID[],
  p_admin_notes text DEFAULT ''
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase RECORD;
  v_buyer_balance_before INTEGER;
  v_buyer_balance INTEGER;
  v_rejected_count INTEGER := 0;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  FOR v_purchase IN
    SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
    FROM public.item_purchases ip
    JOIN public.store_items si ON si.id = ip.store_item_id
    WHERE ip.id = ANY(p_purchase_ids)
      AND ip.admin_status = 'pending_review'
    ORDER BY ip.created_at
  LOOP
    -- Refund buyer
    SELECT balance INTO v_buyer_balance_before
    FROM public.profiles WHERE user_id = v_purchase.buyer_id FOR UPDATE;

    UPDATE public.profiles SET balance = balance + v_purchase.price
    WHERE user_id = v_purchase.buyer_id
    RETURNING balance INTO v_buyer_balance;

    INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
    VALUES (
      v_purchase.buyer_id, v_purchase.price, v_buyer_balance_before, v_buyer_balance,
      'refund',
      'Возврат: ' || v_purchase.item_title,
      v_purchase.store_item_id, 'store_item'
    );

    -- Update purchase status
    UPDATE public.item_purchases
    SET admin_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes
    WHERE id = v_purchase.id;

    UPDATE public.seller_earnings
    SET status = 'rejected'
    WHERE source_id = v_purchase.id;

    -- Restore exclusive lyrics back to sale
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
      v_purchase.item_title || ' — ' || v_purchase.price || ' ₽ возвращено',
      auth.uid(),
      'item_purchase',
      v_purchase.id
    );

    -- Notify seller
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_purchase.seller_id,
      'deal_rejected',
      'Сделка отклонена',
      v_purchase.item_title || ' — ' ||
        CASE
          WHEN v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false)
          THEN COALESCE(NULLIF(p_admin_notes, ''), 'Администрация отклонила сделку') || '. Текст снова доступен для продажи.'
          ELSE COALESCE(NULLIF(p_admin_notes, ''), 'Администрация отклонила сделку')
        END,
      auth.uid(),
      'item_purchase',
      v_purchase.id
    );

    v_rejected_count := v_rejected_count + 1;
  END LOOP;

  RETURN v_rejected_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.batch_reject_purchases(UUID[], text) TO authenticated;
