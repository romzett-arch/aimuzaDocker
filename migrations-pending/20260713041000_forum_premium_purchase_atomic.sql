-- Atomic premium forum content purchase. The client must never control price
-- or perform balance deduction and entitlement creation as separate requests.

CREATE OR REPLACE FUNCTION public.forum_purchase_premium_content(p_topic_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_buyer_id uuid := auth.uid();
  v_content public.forum_premium_content%ROWTYPE;
  v_credits integer;
BEGIN
  IF v_buyer_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  SELECT * INTO v_content
  FROM public.forum_premium_content
  WHERE topic_id = p_topic_id AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Премиальный материал не найден';
  END IF;

  IF v_content.author_id = v_buyer_id THEN
    RETURN jsonb_build_object('success', true, 'already_purchased', true, 'owner', true);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.forum_content_purchases
    WHERE topic_id = p_topic_id AND buyer_id = v_buyer_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'already_purchased', true);
  END IF;

  SELECT COALESCE(credits, 0) INTO v_credits
  FROM public.profiles
  WHERE user_id = v_buyer_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;
  IF v_content.price_credits < 0 THEN
    RAISE EXCEPTION 'Некорректная цена материала';
  END IF;
  IF v_credits < v_content.price_credits THEN
    RAISE EXCEPTION 'Недостаточно кредитов';
  END IF;

  UPDATE public.profiles
  SET credits = COALESCE(credits, 0) - v_content.price_credits
  WHERE user_id = v_buyer_id;

  INSERT INTO public.forum_content_purchases(topic_id, buyer_id, price_paid)
  VALUES (p_topic_id, v_buyer_id, v_content.price_credits);

  UPDATE public.forum_premium_content
  SET purchases_count = purchases_count + 1,
      revenue_total = revenue_total + v_content.price_credits
  WHERE id = v_content.id;

  RETURN jsonb_build_object(
    'success', true,
    'already_purchased', false,
    'price_paid', v_content.price_credits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.forum_purchase_premium_content(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_purchase_premium_content(uuid) TO authenticated, service_role;
