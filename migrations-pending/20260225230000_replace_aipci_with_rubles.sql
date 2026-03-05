-- Replace AiPCI with ₽ in process_store_item_purchase notification text

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

  SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_item.seller_id FOR UPDATE;

  UPDATE public.profiles SET balance = balance + v_net_amount
  WHERE user_id = v_item.seller_id
  RETURNING balance INTO v_seller_balance;

  INSERT INTO public.item_purchases (
    buyer_id, seller_id, store_item_id, item_type, source_id,
    price, license_type, platform_fee, net_amount
  )
  VALUES (
    p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type,
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount
  )
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (user_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id, v_platform_fee, v_net_amount);

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase',
    'Покупка: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (
    v_item.seller_id, v_net_amount, v_seller_balance_before, v_seller_balance,
    'sale_income',
    'Продажа: ' || v_item.title,
    p_store_item_id, 'store_item'
  );

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
    '💰 Продажа: ' || v_item.title,
    'Ваш товар куплен за ' || v_item.price || ' ₽',
    p_buyer_id,
    'store_item',
    p_store_item_id
  );

  RETURN v_purchase_id;
END;
$$;

-- Update setting descriptions
UPDATE public.settings SET description = 'Стоимость суперлайка в рублях'
WHERE key = 'voting_superlike_cost';

-- Fix existing notifications
UPDATE public.notifications SET message = REPLACE(message, 'AiPCI', '₽')
WHERE message LIKE '%AiPCI%';
