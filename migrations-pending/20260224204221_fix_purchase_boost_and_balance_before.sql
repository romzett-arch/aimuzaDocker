-- Fix: добавить balance_before если отсутствует + переписать purchase_track_boost с деталями

SET client_encoding = 'UTF8';

-- ============================================================
-- 0. Удалить старую перегруженную версию purchase_track_boost (4 аргумента)
--    Иначе PostgREST не может определить, какую вызывать → 400 Bad Request
-- ============================================================
DROP FUNCTION IF EXISTS public.purchase_track_boost(uuid, uuid, integer, integer);

-- ============================================================
-- 1. Добавить balance_before если не существует
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'balance_transactions'
      AND column_name = 'balance_before'
  ) THEN
    ALTER TABLE public.balance_transactions ADD COLUMN balance_before INTEGER;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'balance_transactions'
      AND column_name = 'metadata'
  ) THEN
    ALTER TABLE public.balance_transactions ADD COLUMN metadata JSONB DEFAULT NULL;
  END IF;
END $$;

-- ============================================================
-- 2. Переписать purchase_track_boost с названием трека и деталями
-- ============================================================

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER DEFAULT 1
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_user_balance NUMERIC;
  v_new_balance NUMERIC;
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMP WITH TIME ZONE;
  v_boost_type TEXT;
  v_track_title TEXT;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u043e\u0431\u0445\u043e\u0434\u0438\u043c\u0430 \u0430\u0432\u0442\u043e\u0440\u0438\u0437\u0430\u0446\u0438\u044f');
  END IF;

  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id;

  IF v_track_title IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u0422\u0440\u0435\u043a \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d \u0438\u043b\u0438 \u043d\u0435 \u043f\u0440\u0438\u043d\u0430\u0434\u043b\u0435\u0436\u0438\u0442 \u0432\u0430\u043c');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.track_promotions
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', E'\u0422\u0440\u0435\u043a \u0443\u0436\u0435 \u043f\u0440\u043e\u0434\u0432\u0438\u0433\u0430\u0435\u0442\u0441\u044f');
  END IF;

  CASE p_boost_duration_hours
    WHEN 1 THEN
      v_service_name := 'boost_track_1h';
      v_boost_type := 'standard';
    WHEN 6 THEN
      v_service_name := 'boost_track_6h';
      v_boost_type := 'premium';
    WHEN 24 THEN
      v_service_name := 'boost_track_24h';
      v_boost_type := 'top';
    ELSE RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u0432\u0435\u0440\u043d\u0430\u044f \u0434\u043b\u0438\u0442\u0435\u043b\u044c\u043d\u043e\u0441\u0442\u044c');
  END CASE;

  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;

  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', E'\u0423\u0441\u043b\u0443\u0433\u0430 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u0430');
  END IF;

  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id FOR UPDATE;

  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', E'\u041d\u0435\u0434\u043e\u0441\u0442\u0430\u0442\u043e\u0447\u043d\u043e \u0441\u0440\u0435\u0434\u0441\u0442\u0432', 'required', v_price, 'balance', v_user_balance);
  END IF;

  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id
    RETURNING balance INTO v_new_balance;

  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;

  UPDATE public.track_promotions
  SET is_active = false
  WHERE track_id = p_track_id;

  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;

  -- Описание: "Буст трека «Title» на X ч. (Type)"
  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after, metadata
  ) VALUES (
    v_user_id,
    -v_price,
    'purchase',
    E'\u0411\u0443\u0441\u0442 \u0442\u0440\u0435\u043a\u0430 \u00ab' || COALESCE(v_track_title, E'\u2014') || E'\u00bb \u043d\u0430 ' || p_boost_duration_hours || E' \u0447. (' || v_boost_type || ')',
    v_promotion_id,
    'promotion',
    v_user_balance,
    v_new_balance,
    jsonb_build_object('track_id', p_track_id, 'track_title', v_track_title, 'duration_hours', p_boost_duration_hours, 'boost_type', v_boost_type, 'expires_at', v_expires_at)
  );

  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', v_price
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER) TO authenticated;
