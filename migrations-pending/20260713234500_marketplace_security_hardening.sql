-- Marketplace security hardening for the custom REST gateway and PostgreSQL clients.

-- Reject forged listings even when a client talks directly to PostgreSQL/PostgREST.
CREATE OR REPLACE FUNCTION public.validate_store_item_source()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.seller_id IS NULL OR NEW.source_id IS NULL THEN
    RAISE EXCEPTION 'Marketplace seller and source are required';
  END IF;
  IF NEW.item_type NOT IN ('prompt', 'lyrics') THEN
    RAISE EXCEPTION 'Unsupported Marketplace item type';
  END IF;
  IF NEW.price IS NULL OR NEW.price < 0 THEN
    RAISE EXCEPTION 'Marketplace price must be a non-negative integer';
  END IF;

  IF NEW.item_type = 'prompt' AND NOT EXISTS (
    SELECT 1 FROM public.user_prompts
    WHERE id = NEW.source_id AND user_id = NEW.seller_id
  ) THEN
    RAISE EXCEPTION 'Marketplace source does not belong to the seller';
  END IF;

  IF NEW.item_type = 'lyrics' AND NOT EXISTS (
    SELECT 1 FROM public.lyrics_items
    WHERE id = NEW.source_id AND user_id = NEW.seller_id
  ) THEN
    RAISE EXCEPTION 'Marketplace source does not belong to the seller';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_store_item_source_trigger ON public.store_items;
CREATE TRIGGER validate_store_item_source_trigger
BEFORE INSERT OR UPDATE OF seller_id, source_id, item_type, price
ON public.store_items
FOR EACH ROW
EXECUTE FUNCTION public.validate_store_item_source();

CREATE UNIQUE INDEX IF NOT EXISTS item_purchases_buyer_store_unique
  ON public.item_purchases (buyer_id, store_item_id);

-- Rebuild Marketplace RLS policies. The custom owner-connected REST gateway also
-- enforces equivalent scopes in marketplace-rest-policy.js.
ALTER TABLE public.store_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_prompts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lyrics_items ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  v_policy record;
BEGIN
  FOR v_policy IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('store_items', 'item_purchases', 'user_prompts', 'lyrics_items')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I',
      v_policy.policyname, v_policy.schemaname, v_policy.tablename);
  END LOOP;
END;
$$;

CREATE POLICY store_items_read ON public.store_items
FOR SELECT USING (
  seller_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY store_items_insert_own ON public.store_items
FOR INSERT WITH CHECK (
  seller_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY store_items_update_own ON public.store_items
FOR UPDATE
USING (seller_id = auth.uid() OR public.is_admin(auth.uid()) OR auth.role() = 'service_role')
WITH CHECK (seller_id = auth.uid() OR public.is_admin(auth.uid()) OR auth.role() = 'service_role');

CREATE POLICY store_items_delete_own ON public.store_items
FOR DELETE USING (
  seller_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY item_purchases_read_parties ON public.item_purchases
FOR SELECT USING (
  buyer_id = auth.uid()
  OR seller_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY item_purchases_admin_write ON public.item_purchases
FOR ALL
USING (public.is_admin(auth.uid()) OR auth.role() = 'service_role')
WITH CHECK (public.is_admin(auth.uid()) OR auth.role() = 'service_role');

CREATE POLICY user_prompts_read_authorized ON public.user_prompts
FOR SELECT USING (
  user_id = auth.uid()
  OR (is_public IS TRUE AND COALESCE(price, 0) = 0)
  OR EXISTS (
    SELECT 1
    FROM public.item_purchases ip
    WHERE ip.buyer_id = auth.uid()
      AND ip.item_type = 'prompt'
      AND ip.source_id = user_prompts.id
      AND COALESCE(ip.admin_status, 'approved') <> 'rejected'
  )
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY user_prompts_insert_own ON public.user_prompts
FOR INSERT WITH CHECK (
  (user_id = auth.uid() AND public.can_write_during_maintenance())
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY user_prompts_update_own ON public.user_prompts
FOR UPDATE
USING (user_id = auth.uid() OR public.is_admin(auth.uid()) OR auth.role() = 'service_role')
WITH CHECK (
  (user_id = auth.uid() AND public.can_write_during_maintenance())
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY user_prompts_delete_own ON public.user_prompts
FOR DELETE USING (
  (user_id = auth.uid() AND public.can_write_during_maintenance())
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY lyrics_items_read_authorized ON public.lyrics_items
FOR SELECT USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1
    FROM public.item_purchases ip
    WHERE ip.buyer_id = auth.uid()
      AND ip.item_type = 'lyrics'
      AND ip.source_id = lyrics_items.id
      AND COALESCE(ip.admin_status, 'approved') <> 'rejected'
  )
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY lyrics_items_insert_own ON public.lyrics_items
FOR INSERT WITH CHECK (
  user_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE POLICY lyrics_items_update_own ON public.lyrics_items
FOR UPDATE
USING (user_id = auth.uid() OR public.is_admin(auth.uid()) OR auth.role() = 'service_role')
WITH CHECK (user_id = auth.uid() OR public.is_admin(auth.uid()) OR auth.role() = 'service_role');

CREATE POLICY lyrics_items_delete_own ON public.lyrics_items
FOR DELETE USING (
  user_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

DROP FUNCTION IF EXISTS public.has_purchased_item(UUID, UUID);
CREATE FUNCTION public.has_purchased_item(
  p_user_id UUID,
  p_store_item_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: user_id must match authenticated user';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.item_purchases
    WHERE buyer_id = p_user_id
      AND store_item_id = p_store_item_id
      AND COALESCE(admin_status, 'approved') <> 'rejected'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_purchased_item(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_purchased_item(UUID, UUID) TO authenticated;

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
  IF auth.uid() IS NULL OR p_buyer_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_item
  FROM public.store_items
  WHERE id = p_store_item_id
    AND is_active IS TRUE
    AND item_type IN ('prompt', 'lyrics')
  FOR UPDATE;

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Item not found or not available';
  END IF;
  IF v_item.price IS NULL OR v_item.price < 0 THEN
    RAISE EXCEPTION 'Invalid item price';
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

  IF v_item.item_type = 'prompt' AND NOT EXISTS (
    SELECT 1 FROM public.user_prompts
    WHERE id = v_item.source_id AND user_id = v_item.seller_id
  ) THEN
    RAISE EXCEPTION 'Marketplace source is invalid';
  END IF;
  IF v_item.item_type = 'lyrics' AND NOT EXISTS (
    SELECT 1 FROM public.lyrics_items
    WHERE id = v_item.source_id AND user_id = v_item.seller_id
  ) THEN
    RAISE EXCEPTION 'Marketplace source is invalid';
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
