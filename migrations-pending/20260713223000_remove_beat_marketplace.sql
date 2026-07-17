-- Полное удаление продажи битов. Маркетплейс поддерживает только промпты и тексты.

DELETE FROM public.store_items WHERE item_type = 'beat';

DROP FUNCTION IF EXISTS public.process_beat_purchase(UUID, UUID);
DROP FUNCTION IF EXISTS public.process_beat_purchase(UUID, UUID, TEXT);
DROP TABLE IF EXISTS public.beat_purchases CASCADE;
DROP TABLE IF EXISTS public.store_beats CASCADE;

DELETE FROM public.settings
WHERE key IN ('feature_beat_store', 'min_beat_price', 'beat_store_enabled');

ALTER TABLE public.store_items
  DROP CONSTRAINT IF EXISTS store_items_item_type_check;
ALTER TABLE public.store_items
  ADD CONSTRAINT store_items_item_type_check
  CHECK (item_type IN ('prompt', 'lyrics'));

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

  SELECT * INTO v_item
  FROM public.store_items
  WHERE id = p_store_item_id
    AND is_active = true
    AND item_type IN ('prompt', 'lyrics');

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

  SELECT COALESCE(rt.marketplace_commission, 0.10)
  INTO v_commission_rate
  FROM public.forum_user_stats fus
  JOIN public.reputation_tiers rt ON rt.key = fus.tier
  WHERE fus.user_id = v_item.seller_id;

  v_commission_rate := COALESCE(v_commission_rate, 0.10);
  v_platform_fee := CASE
    WHEN v_item.price = 0 THEN 0
    ELSE GREATEST(1, ROUND(v_item.price * v_commission_rate))
  END;
  v_net_amount := v_item.price - v_platform_fee;
  v_is_escrow := (v_item.item_type = 'lyrics');

  SELECT balance INTO v_buyer_balance_before
  FROM public.profiles
  WHERE user_id = p_buyer_id
  FOR UPDATE;

  IF v_buyer_balance_before IS NULL OR v_buyer_balance_before < v_item.price THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_item.price
  WHERE user_id = p_buyer_id
  RETURNING balance INTO v_buyer_balance;

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

  INSERT INTO public.seller_earnings (
    user_id, amount, source_type, source_id, platform_fee, net_amount, status
  )
  VALUES (
    v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id,
    v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending' ELSE 'available' END
  );

  UPDATE public.store_items
  SET sales_count = sales_count + 1
  WHERE id = p_store_item_id;

  INSERT INTO public.balance_transactions (
    user_id, amount, balance_before, balance_after, type,
    description, reference_id, reference_type
  )
  VALUES (
    p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase', 'Покупка: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

  IF v_is_escrow THEN
    INSERT INTO public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id
    )
    VALUES (
      v_item.seller_id, 'item_sold', 'Продажа: ' || v_item.title,
      'Ваш текст куплен за ' || v_item.price || ' ₽. Ожидает подтверждения администрации.',
      p_buyer_id, 'item_purchase', v_purchase_id
    );

    FOR v_admin_id IN
      SELECT user_id FROM public.user_roles WHERE role IN ('admin', 'super_admin')
    LOOP
      INSERT INTO public.notifications (
        user_id, type, title, message, actor_id, target_type, target_id
      )
      VALUES (
        v_admin_id, 'deal_pending_review', 'Новая сделка на рассмотрении',
        v_item.title || ' — ' || v_item.price || ' ₽ (текст)',
        p_buyer_id, 'item_purchase', v_purchase_id
      );
    END LOOP;
  ELSE
    SELECT balance INTO v_seller_balance_before
    FROM public.profiles
    WHERE user_id = v_item.seller_id
    FOR UPDATE;

    UPDATE public.profiles
    SET balance = balance + v_net_amount
    WHERE user_id = v_item.seller_id
    RETURNING balance INTO v_seller_balance;

    INSERT INTO public.balance_transactions (
      user_id, amount, balance_before, balance_after, type,
      description, reference_id, reference_type
    )
    VALUES (
      v_item.seller_id, v_net_amount, v_seller_balance_before, v_seller_balance,
      'sale_income', 'Продажа: ' || v_item.title,
      p_store_item_id, 'store_item'
    );

    INSERT INTO public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id
    )
    VALUES (
      v_item.seller_id, 'item_sold', 'Продажа: ' || v_item.title,
      'Ваш промпт куплен за ' || v_item.price || ' ₽. Средства зачислены.',
      p_buyer_id, 'item_purchase', v_purchase_id
    );
  END IF;

  IF v_item.is_exclusive THEN
    UPDATE public.store_items SET is_active = false WHERE id = p_store_item_id;

    IF v_item.item_type = 'prompt' THEN
      UPDATE public.user_prompts SET is_public = false WHERE id = v_item.source_id;
    ELSE
      UPDATE public.lyrics_items
      SET is_active = false, is_for_sale = false
      WHERE id = v_item.source_id;
    END IF;
  END IF;

  RETURN v_purchase_id;
END;
$$;

REVOKE ALL ON FUNCTION public.process_store_item_purchase(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_store_item_purchase(UUID, UUID) TO authenticated;
