-- Marketplace escrow and immutable license evidence.
-- AIMUZA guarantees the transaction workflow and preservation of its evidence;
-- authorship itself remains a statement of the seller and is not created by deposit.

ALTER TABLE public.item_purchases
  ADD COLUMN IF NOT EXISTS license_terms_snapshot text,
  ADD COLUMN IF NOT EXISTS license_agreement_hash text,
  ADD COLUMN IF NOT EXISTS license_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS agreement_number text,
  ADD COLUMN IF NOT EXISTS guarantee_status text;

CREATE OR REPLACE FUNCTION public.marketplace_default_license_terms(
  p_license_type text,
  p_item_type text,
  p_custom_terms text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_subject text := CASE WHEN p_item_type = 'lyrics' THEN 'текста песни' ELSE 'промпта' END;
  v_terms text;
BEGIN
  v_terms := CASE p_license_type
    WHEN 'exclusive' THEN
      'Исключительная лицензия на использование ' || v_subject ||
      ': воспроизведение, переработка, включение в музыкальные и аудиовизуальные произведения, распространение и доведение созданных произведений до всеобщего сведения. Территория — весь мир. Срок — весь срок действия исключительного права. После подтверждения сделки продавец не вправе выдавать аналогичные лицензии или продолжать использование объекта в переданном объёме. Авторство и личные неимущественные права не передаются.'
    WHEN 'unlimited' THEN
      'Простая (неисключительная) лицензия на неограниченное число использований ' || v_subject ||
      ': воспроизведение, переработка, включение в музыкальные и аудиовизуальные произведения, распространение и доведение созданных произведений до всеобщего сведения. Территория — весь мир. Срок — весь срок действия исключительного права. Перепродажа исходника и выдача сублицензий на исходник не допускаются.'
    ELSE
      'Простая (неисключительная) лицензия на использование ' || v_subject ||
      ' в одном создаваемом проекте: воспроизведение, переработка, включение в музыкальное или аудиовизуальное произведение, распространение и доведение созданного произведения до всеобщего сведения. Территория — весь мир. Срок — весь срок действия исключительного права. Перепродажа исходника и выдача сублицензий на исходник не допускаются.'
  END;

  IF NULLIF(btrim(COALESCE(p_custom_terms, '')), '') IS NOT NULL THEN
    v_terms := v_terms || E'\n\nДополнительные условия продавца: ' || btrim(p_custom_terms);
  END IF;

  RETURN v_terms;
END;
$$;

CREATE OR REPLACE FUNCTION public.item_purchase_capture_license_evidence()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.store_items%ROWTYPE;
BEGIN
  SELECT * INTO v_item FROM public.store_items WHERE id = NEW.store_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Marketplace item not found';
  END IF;

  NEW.license_terms_snapshot := public.marketplace_default_license_terms(
    NEW.license_type,
    NEW.item_type,
    v_item.license_terms
  );
  NEW.license_accepted_at := COALESCE(NEW.license_accepted_at, now());
  NEW.agreement_number := COALESCE(
    NEW.agreement_number,
    'AIM-LIC-' || upper(substr(replace(NEW.id::text, '-', ''), 1, 16))
  );
  NEW.guarantee_status := CASE
    WHEN NEW.admin_status = 'pending_review' THEN 'funds_held'
    WHEN NEW.admin_status = 'approved' THEN 'completed'
    WHEN NEW.admin_status = 'rejected' THEN 'refunded'
    ELSE 'recorded'
  END;
  NEW.license_agreement_hash := encode(digest(convert_to(
    concat_ws('|', NEW.id::text, NEW.buyer_id::text, NEW.seller_id::text,
      NEW.store_item_id::text, NEW.item_type, NEW.source_id::text,
      NEW.price::text, NEW.license_type, NEW.license_terms_snapshot,
      NEW.license_accepted_at::text), 'UTF8'), 'sha256'), 'hex');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS item_purchase_capture_license_evidence ON public.item_purchases;
CREATE TRIGGER item_purchase_capture_license_evidence
BEFORE INSERT ON public.item_purchases
FOR EACH ROW EXECUTE FUNCTION public.item_purchase_capture_license_evidence();

-- Preserve evidence for existing purchases. Their acceptance time is the purchase time.
UPDATE public.item_purchases ip
SET license_terms_snapshot = public.marketplace_default_license_terms(
      ip.license_type, ip.item_type, si.license_terms),
    license_accepted_at = COALESCE(ip.license_accepted_at, ip.created_at),
    agreement_number = COALESCE(ip.agreement_number,
      'AIM-LIC-' || upper(substr(replace(ip.id::text, '-', ''), 1, 16))),
    guarantee_status = CASE
      WHEN ip.admin_status = 'pending_review' THEN 'funds_held'
      WHEN ip.admin_status = 'rejected' THEN 'refunded'
      ELSE 'completed'
    END
FROM public.store_items si
WHERE si.id = ip.store_item_id
  AND (ip.license_terms_snapshot IS NULL OR ip.license_accepted_at IS NULL
    OR ip.agreement_number IS NULL OR ip.guarantee_status IS NULL);

UPDATE public.item_purchases
SET license_agreement_hash = encode(digest(convert_to(
  concat_ws('|', id::text, buyer_id::text, seller_id::text, store_item_id::text,
    item_type, source_id::text, price::text, license_type,
    license_terms_snapshot, license_accepted_at::text), 'UTF8'), 'sha256'), 'hex')
WHERE license_agreement_hash IS NULL;

ALTER TABLE public.item_purchases
  ALTER COLUMN license_terms_snapshot SET NOT NULL,
  ALTER COLUMN license_agreement_hash SET NOT NULL,
  ALTER COLUMN license_accepted_at SET NOT NULL,
  ALTER COLUMN agreement_number SET NOT NULL,
  ALTER COLUMN guarantee_status SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS item_purchases_agreement_number_key
  ON public.item_purchases (agreement_number);

DROP POLICY IF EXISTS lyrics_items_read_authorized ON public.lyrics_items;
CREATE POLICY lyrics_items_read_authorized ON public.lyrics_items
FOR SELECT USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.item_purchases ip
    WHERE ip.buyer_id = auth.uid()
      AND ip.item_type = 'lyrics'
      AND ip.source_id = lyrics_items.id
      AND COALESCE(ip.admin_status, 'approved') = 'approved'
  )
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

DROP POLICY IF EXISTS user_prompts_read_authorized ON public.user_prompts;
CREATE POLICY user_prompts_read_authorized ON public.user_prompts
FOR SELECT USING (
  user_id = auth.uid()
  OR (is_public IS TRUE AND COALESCE(price, 0) = 0)
  OR EXISTS (
    SELECT 1 FROM public.item_purchases ip
    WHERE ip.buyer_id = auth.uid()
      AND ip.item_type = 'prompt'
      AND ip.source_id = user_prompts.id
      AND COALESCE(ip.admin_status, 'approved') = 'approved'
  )
  OR public.is_admin(auth.uid())
  OR auth.role() = 'service_role'
);

CREATE OR REPLACE FUNCTION public.has_purchased_item(p_user_id uuid, p_store_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: user_id must match authenticated user';
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.item_purchases
    WHERE buyer_id = p_user_id
      AND store_item_id = p_store_item_id
      AND COALESCE(admin_status, 'approved') = 'approved'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.process_store_item_purchase(p_buyer_id uuid, p_store_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD; v_purchase_id uuid; v_platform_fee integer; v_net_amount integer;
  v_buyer_balance_before integer; v_buyer_balance integer;
  v_seller_balance_before integer; v_seller_balance integer;
  v_admin_id uuid; v_is_escrow boolean; v_commission_rate numeric;
BEGIN
  IF auth.uid() IS NULL OR p_buyer_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_item FROM public.store_items
  WHERE id = p_store_item_id AND is_active IS TRUE
    AND item_type IN ('prompt', 'lyrics') FOR UPDATE;
  IF v_item IS NULL THEN RAISE EXCEPTION 'Item not found or not available'; END IF;
  IF v_item.price IS NULL OR v_item.price < 0 THEN RAISE EXCEPTION 'Invalid item price'; END IF;
  IF v_item.seller_id = p_buyer_id THEN RAISE EXCEPTION 'Cannot purchase your own item'; END IF;
  IF EXISTS (SELECT 1 FROM public.item_purchases
    WHERE store_item_id = p_store_item_id AND buyer_id = p_buyer_id
      AND COALESCE(admin_status, 'approved') <> 'rejected') THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;
  IF v_item.is_exclusive AND EXISTS (SELECT 1 FROM public.item_purchases
    WHERE store_item_id = p_store_item_id
      AND COALESCE(admin_status, 'approved') <> 'rejected') THEN
    RAISE EXCEPTION 'Exclusive item already reserved';
  END IF;
  IF v_item.item_type = 'prompt' AND NOT EXISTS (SELECT 1 FROM public.user_prompts
    WHERE id = v_item.source_id AND user_id = v_item.seller_id) THEN
    RAISE EXCEPTION 'Marketplace source is invalid';
  END IF;
  IF v_item.item_type = 'lyrics' AND NOT EXISTS (SELECT 1 FROM public.lyrics_items
    WHERE id = v_item.source_id AND user_id = v_item.seller_id) THEN
    RAISE EXCEPTION 'Marketplace source is invalid';
  END IF;

  SELECT COALESCE(rt.marketplace_commission, 0.10) INTO v_commission_rate
  FROM public.forum_user_stats fus JOIN public.reputation_tiers rt ON rt.key = fus.tier
  WHERE fus.user_id = v_item.seller_id;
  v_commission_rate := COALESCE(v_commission_rate, 0.10);
  v_platform_fee := CASE WHEN v_item.price = 0 THEN 0 ELSE GREATEST(1, ROUND(v_item.price * v_commission_rate)) END;
  v_net_amount := v_item.price - v_platform_fee;
  v_is_escrow := v_item.item_type = 'lyrics';

  SELECT balance INTO v_buyer_balance_before FROM public.profiles
  WHERE user_id = p_buyer_id FOR UPDATE;
  IF v_buyer_balance_before IS NULL OR v_buyer_balance_before < v_item.price THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;
  UPDATE public.profiles SET balance = balance - v_item.price WHERE user_id = p_buyer_id
  RETURNING balance INTO v_buyer_balance;

  INSERT INTO public.item_purchases (buyer_id, seller_id, store_item_id, item_type,
    source_id, price, license_type, platform_fee, net_amount, admin_status)
  VALUES (p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type,
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount,
    CASE WHEN v_is_escrow THEN 'pending_review' ELSE 'approved' END)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (user_id, amount, source_type, source_id,
    platform_fee, net_amount, status)
  VALUES (v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id,
    v_platform_fee, v_net_amount, CASE WHEN v_is_escrow THEN 'pending' ELSE 'available' END);

  IF NOT v_is_escrow THEN
    UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;
  END IF;
  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after,
    type, description, reference_id, reference_type)
  VALUES (p_buyer_id, -v_item.price, v_buyer_balance_before, v_buyer_balance,
    'item_purchase', 'Покупка: ' || v_item.title, p_store_item_id, 'store_item');

  IF v_is_escrow THEN
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (v_item.seller_id, 'item_sold', 'Текст куплен — ожидается проверка',
      'Сделка «' || v_item.title || '» на ' || v_item.price || ' ₽. Деньги удерживаются AIMUZA до решения администратора.',
      p_buyer_id, 'item_purchase', v_purchase_id);
    FOR v_admin_id IN SELECT user_id FROM public.user_roles WHERE role IN ('admin', 'super_admin') LOOP
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (v_admin_id, 'deal_pending_review', 'Нужно проверить сделку с текстом',
        'Покупка «' || v_item.title || '» на ' || v_item.price || ' ₽ ожидает подтверждения. Деньги удержаны, исходник покупателю ещё не открыт.',
        p_buyer_id, 'item_purchase', v_purchase_id);
    END LOOP;
  ELSE
    SELECT balance INTO v_seller_balance_before FROM public.profiles
    WHERE user_id = v_item.seller_id FOR UPDATE;
    UPDATE public.profiles SET balance = balance + v_net_amount WHERE user_id = v_item.seller_id
    RETURNING balance INTO v_seller_balance;
    INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after,
      type, description, reference_id, reference_type)
    VALUES (v_item.seller_id, v_net_amount, v_seller_balance_before, v_seller_balance,
      'sale_income', 'Продажа: ' || v_item.title, p_store_item_id, 'store_item');
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (v_item.seller_id, 'item_sold', 'Промпт продан',
      'Промпт «' || v_item.title || '» куплен за ' || v_item.price || ' ₽. Средства зачислены.',
      p_buyer_id, 'item_purchase', v_purchase_id);
  END IF;

  IF v_item.is_exclusive AND NOT v_is_escrow THEN
    UPDATE public.store_items SET is_active = false WHERE id = p_store_item_id;
    UPDATE public.user_prompts SET is_public = false WHERE id = v_item.source_id;
  END IF;
  RETURN v_purchase_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_approve_purchase(p_purchase_id uuid, p_admin_notes text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_purchase RECORD; v_seller_balance_before integer; v_seller_balance integer; v_item_title text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Forbidden: admin only'; END IF;
  SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
  INTO v_purchase FROM public.item_purchases ip JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id FOR UPDATE OF ip;
  IF v_purchase IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF v_purchase.admin_status <> 'pending_review' THEN RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status; END IF;
  v_item_title := v_purchase.item_title;
  SELECT balance INTO v_seller_balance_before FROM public.profiles WHERE user_id = v_purchase.seller_id FOR UPDATE;
  UPDATE public.profiles SET balance = balance + v_purchase.net_amount WHERE user_id = v_purchase.seller_id RETURNING balance INTO v_seller_balance;
  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (v_purchase.seller_id, v_purchase.net_amount, v_seller_balance_before, v_seller_balance,
    'sale_income', 'Продажа подтверждена AIMUZA: ' || v_item_title, v_purchase.store_item_id, 'store_item');
  UPDATE public.item_purchases SET admin_status = 'approved', guarantee_status = 'completed',
    reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes WHERE id = p_purchase_id;
  UPDATE public.seller_earnings SET status = 'available' WHERE source_id = p_purchase_id;
  UPDATE public.store_items SET sales_count = sales_count + 1,
    is_active = CASE WHEN v_purchase.item_is_exclusive THEN false ELSE is_active END
  WHERE id = v_purchase.store_item_id;
  IF v_purchase.item_type = 'lyrics' AND COALESCE(v_purchase.item_is_exclusive, false) THEN
    UPDATE public.lyrics_items SET user_id = v_purchase.buyer_id, is_for_sale = false, is_active = false
    WHERE id = v_purchase.source_id;
  END IF;
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (v_purchase.seller_id, 'deal_approved', 'Сделка подтверждена AIMUZA',
    '«' || v_item_title || '»: ' || v_purchase.net_amount || ' ₽ зачислено. Условия лицензии зафиксированы в сделке.',
    auth.uid(), 'item_purchase', p_purchase_id);
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (v_purchase.buyer_id, 'deal_approved', 'Покупка подтверждена — исходник открыт',
    '«' || v_item_title || '»: AIMUZA завершила сделку. Исходник и зафиксированные условия лицензии доступны в «Моих покупках».',
    auth.uid(), 'item_purchase', p_purchase_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_purchase(p_purchase_id uuid, p_admin_notes text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_purchase RECORD; v_buyer_balance_before integer; v_buyer_balance integer; v_item_title text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Forbidden: admin only'; END IF;
  SELECT ip.*, si.title AS item_title, si.is_exclusive AS item_is_exclusive
  INTO v_purchase FROM public.item_purchases ip JOIN public.store_items si ON si.id = ip.store_item_id
  WHERE ip.id = p_purchase_id FOR UPDATE OF ip;
  IF v_purchase IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF v_purchase.admin_status <> 'pending_review' THEN RAISE EXCEPTION 'Purchase not pending review: %', v_purchase.admin_status; END IF;
  v_item_title := v_purchase.item_title;
  SELECT balance INTO v_buyer_balance_before FROM public.profiles WHERE user_id = v_purchase.buyer_id FOR UPDATE;
  UPDATE public.profiles SET balance = balance + v_purchase.price WHERE user_id = v_purchase.buyer_id RETURNING balance INTO v_buyer_balance;
  INSERT INTO public.balance_transactions (user_id, amount, balance_before, balance_after, type, description, reference_id, reference_type)
  VALUES (v_purchase.buyer_id, v_purchase.price, v_buyer_balance_before, v_buyer_balance,
    'refund', 'Возврат по отклонённой сделке: ' || v_item_title, v_purchase.store_item_id, 'store_item');
  UPDATE public.item_purchases SET admin_status = 'rejected', guarantee_status = 'refunded',
    reviewed_by = auth.uid(), reviewed_at = now(), admin_notes = p_admin_notes WHERE id = p_purchase_id;
  UPDATE public.seller_earnings SET status = 'rejected' WHERE source_id = p_purchase_id;
  UPDATE public.store_items si SET is_active = true
  WHERE si.id = v_purchase.store_item_id
    AND si.seller_id = v_purchase.seller_id
    AND NOT EXISTS (SELECT 1 FROM public.item_purchases ip2
      WHERE ip2.store_item_id = si.id AND ip2.id <> p_purchase_id
        AND COALESCE(ip2.admin_status, 'approved') <> 'rejected');
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (v_purchase.buyer_id, 'deal_rejected', 'Сделка отклонена — деньги возвращены',
    '«' || v_item_title || '»: ' || v_purchase.price || ' ₽ возвращено. Исходник не передан.',
    auth.uid(), 'item_purchase', p_purchase_id);
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (v_purchase.seller_id, 'deal_rejected', 'Сделка отклонена',
    '«' || v_item_title || '»: ' || COALESCE(NULLIF(p_admin_notes, ''), 'администрация отклонила сделку') || '. Лот снова доступен.',
    auth.uid(), 'item_purchase', p_purchase_id);
END;
$$;

REVOKE ALL ON FUNCTION public.marketplace_default_license_terms(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketplace_default_license_terms(text, text, text) TO authenticated, service_role;
