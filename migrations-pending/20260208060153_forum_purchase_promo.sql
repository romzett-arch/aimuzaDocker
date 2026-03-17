-- forum_purchase_promo + forum_expire_promos (forum_moderate_promo уже есть, обновляем с fix user_id)
-- Исправление: profiles.id -> profiles.user_id (в проекте user_id = auth.uid())

-- Promo settings (если ещё нет)
INSERT INTO public.forum_automod_settings (key, value, description)
VALUES (
  'promo_settings',
  '{
    "enabled": true,
    "prices": {"text": 500, "banner": 1000, "pinned": 2000},
    "durations": {"text": 7, "banner": 14, "pinned": 7},
    "max_active_per_user": 3,
    "allowed_categories": [],
    "require_ai_check": true,
    "refund_on_rejection": true,
    "refund_percent": 100
  }'::jsonb,
  'Настройки платной рекламы на форуме: цены (₽), длительность, лимиты'
)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = now();

-- RPC: Purchase promo slot
CREATE OR REPLACE FUNCTION public.forum_purchase_promo(
  p_user_id UUID,
  p_promo_type TEXT,
  p_category_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_price NUMERIC;
  v_duration INT;
  v_balance NUMERIC;
  v_active_count INT;
  v_max_active INT;
  v_slot_id UUID;
BEGIN
  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';
  IF v_settings IS NULL OR NOT (v_settings->>'enabled')::boolean THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо-реклама временно недоступна');
  END IF;

  v_price := (v_settings->'prices'->>p_promo_type)::numeric;
  v_duration := (v_settings->'durations'->>p_promo_type)::int;
  IF v_price IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Неверный тип промо');
  END IF;

  -- FIX: profiles.user_id (не id) = auth.uid()
  SELECT balance INTO v_balance FROM profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств. Необходимо: ' || v_price || ' ₽');
  END IF;

  v_max_active := COALESCE((v_settings->>'max_active_per_user')::int, 3);
  SELECT COUNT(*) INTO v_active_count
  FROM forum_promo_slots
  WHERE user_id = p_user_id AND status IN ('pending_content', 'pending_moderation', 'approved');

  IF v_active_count >= v_max_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'Максимум активных промо: ' || v_max_active);
  END IF;

  UPDATE profiles SET balance = balance - v_price WHERE user_id = p_user_id;

  INSERT INTO forum_promo_slots (user_id, promo_type, status, price_rub, duration_days, category_id)
  VALUES (p_user_id, p_promo_type::forum_promo_type, 'pending_content', v_price, v_duration, p_category_id)
  RETURNING id INTO v_slot_id;

  RETURN jsonb_build_object(
    'success', true,
    'slot_id', v_slot_id,
    'price', v_price,
    'duration_days', v_duration,
    'message', 'Промо-слот куплен! Заполните контент и отправьте на модерацию.'
  );
END;
$$;

-- RPC: Moderate promo (обновляем с fix user_id для refund)
CREATE OR REPLACE FUNCTION public.forum_moderate_promo(
  p_slot_id UUID,
  p_moderator_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot RECORD;
  v_settings JSONB;
  v_refund_percent INT;
  v_refund_amount NUMERIC;
BEGIN
  SELECT * INTO v_slot FROM forum_promo_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо-слот не найден');
  END IF;

  IF v_slot.status != 'pending_moderation' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо не на модерации');
  END IF;

  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';

  IF p_action = 'approve' THEN
    UPDATE forum_promo_slots SET
      status = 'approved',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      starts_at = now(),
      expires_at = now() + (v_slot.duration_days || ' days')::interval,
      updated_at = now()
    WHERE id = p_slot_id;

    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_approved', 'promo', p_slot_id::text, jsonb_build_object('promo_type', v_slot.promo_type));

    RETURN jsonb_build_object('success', true, 'message', 'Промо одобрено и опубликовано');

  ELSIF p_action = 'reject' THEN
    v_refund_percent := COALESCE((v_settings->>'refund_percent')::int, 100);
    v_refund_amount := v_slot.price_rub * v_refund_percent / 100;

    -- FIX: profiles.user_id (не id)
    IF v_refund_amount > 0 AND COALESCE((v_settings->>'refund_on_rejection')::boolean, true) THEN
      UPDATE profiles SET balance = balance + v_refund_amount WHERE user_id = v_slot.user_id;
    END IF;

    UPDATE forum_promo_slots SET
      status = 'rejected',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      rejection_reason = p_reason,
      refunded = (v_refund_amount > 0),
      refund_amount = v_refund_amount,
      updated_at = now()
    WHERE id = p_slot_id;

    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_rejected', 'promo', p_slot_id::text,
      jsonb_build_object('reason', p_reason, 'refund', v_refund_amount));

    RETURN jsonb_build_object('success', true, 'message', 'Промо отклонено. Возврат: ' || v_refund_amount || ' ₽');
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Неверное действие');
  END IF;
END;
$$;

-- Trigger: auto-expire promo slots
CREATE OR REPLACE FUNCTION public.forum_expire_promos()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE forum_promo_slots
  SET status = 'expired', updated_at = now()
  WHERE status = 'approved' AND expires_at < now();
END;
$$;
