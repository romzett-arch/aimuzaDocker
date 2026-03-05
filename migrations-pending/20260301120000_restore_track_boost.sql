-- Восстановление функционала буста треков (откат remove_unused_features для boost)
-- addon_services, purchase_track_boost, get_boosted_tracks

-- 1. Восстановить addon_services для буста
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES
  ('boost_track_1h', 'Буст трека (1 час)', 'Поднять трек в ленте на 1 час', 10, 'rocket', true, 20),
  ('boost_track_6h', 'Буст трека (6 часов)', 'Поднять трек в ленте на 6 часов', 40, 'rocket', true, 21),
  ('boost_track_24h', 'Буст трека (24 часа)', 'Поднять трек в ленте на сутки', 100, 'rocket', true, 22)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub,
  icon = EXCLUDED.icon,
  is_active = EXCLUDED.is_active,
  sort_order = EXCLUDED.sort_order;

-- 2. Функция get_boosted_tracks
CREATE OR REPLACE FUNCTION public.get_boosted_tracks(p_limit INTEGER DEFAULT 5)
RETURNS TABLE (
  track_id UUID,
  promotion_id UUID,
  boost_type TEXT,
  expires_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.deactivate_expired_promotions();
  RETURN QUERY
  SELECT
    tp.track_id,
    tp.id AS promotion_id,
    tp.boost_type,
    tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
  ORDER BY
    CASE tp.boost_type WHEN 'top' THEN 1 WHEN 'premium' THEN 2 ELSE 3 END,
    tp.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO anon;

-- 3. Функция purchase_track_boost
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
    RETURN json_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;

  SELECT title INTO v_track_title FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id;
  IF v_track_title IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.track_promotions
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Трек уже продвигается');
  END IF;

  CASE p_boost_duration_hours
    WHEN 1 THEN v_service_name := 'boost_track_1h'; v_boost_type := 'standard';
    WHEN 6 THEN v_service_name := 'boost_track_6h'; v_boost_type := 'premium';
    WHEN 24 THEN v_service_name := 'boost_track_24h'; v_boost_type := 'top';
    ELSE RETURN json_build_object('success', false, 'error', 'Неверная длительность');
  END CASE;

  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;
  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Услуга не найдена');
  END IF;

  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id FOR UPDATE;
  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
  END IF;

  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id
    RETURNING balance INTO v_new_balance;

  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;

  UPDATE public.track_promotions SET is_active = false WHERE track_id = p_track_id;

  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;

  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after, metadata
  ) VALUES (
    v_user_id, -v_price, 'purchase',
    'Буст трека «' || COALESCE(v_track_title, '—') || '» на ' || p_boost_duration_hours || ' ч. (' || v_boost_type || ')',
    v_promotion_id, 'promotion',
    v_user_balance, v_new_balance,
    jsonb_build_object('track_id', p_track_id, 'track_title', v_track_title, 'duration_hours', p_boost_duration_hours, 'boost_type', v_boost_type, 'expires_at', v_expires_at)
  );

  RETURN json_build_object('success', true, 'promotion_id', v_promotion_id, 'expires_at', v_expires_at, 'price', v_price);
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER) TO authenticated;
