-- =============================================
-- TRACK PROMOTIONS: деактивация истекших, admin RPC, инкременты
-- =============================================

-- 0. Совместимость: добавить недостающие колонки (если сервер имеет amount/impressions/clicks)
ALTER TABLE public.track_promotions ADD COLUMN IF NOT EXISTS impressions_count INTEGER DEFAULT 0;
ALTER TABLE public.track_promotions ADD COLUMN IF NOT EXISTS clicks_count INTEGER DEFAULT 0;
ALTER TABLE public.track_promotions ADD COLUMN IF NOT EXISTS price_paid NUMERIC DEFAULT 0;
ALTER TABLE public.track_promotions ADD COLUMN IF NOT EXISTS starts_at TIMESTAMPTZ DEFAULT now();
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='track_promotions' AND column_name='impressions') THEN
    EXECUTE 'UPDATE public.track_promotions SET impressions_count = impressions WHERE impressions IS NOT NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='track_promotions' AND column_name='clicks') THEN
    EXECUTE 'UPDATE public.track_promotions SET clicks_count = clicks WHERE clicks IS NOT NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='track_promotions' AND column_name='amount') THEN
    EXECUTE 'UPDATE public.track_promotions SET price_paid = amount WHERE price_paid IS NULL OR price_paid = 0';
  END IF;
END $$;

-- 1. Функция деактивации истекших промо
CREATE OR REPLACE FUNCTION public.deactivate_expired_promotions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.track_promotions
  SET is_active = false
  WHERE is_active = true AND expires_at < now();
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Вызов деактивации в начале get_boosted_tracks (ленивая очистка при каждом запросе)
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
  -- Деактивируем истекшие промо при каждом запросе
  PERFORM public.deactivate_expired_promotions();
  
  RETURN QUERY
  SELECT 
    tp.track_id,
    tp.id AS promotion_id,
    tp.boost_type,
    tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE 
    tp.is_active = true 
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
  ORDER BY 
    CASE tp.boost_type 
      WHEN 'top' THEN 1 
      WHEN 'premium' THEN 2 
      ELSE 3 
    END,
    tp.created_at DESC
  LIMIT p_limit;
END;
$$;

-- 2. Обновить purchase_track_boost: маппинг длительности -> boost_type (1ч=standard, 6ч=premium, 24ч=top)
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
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMP WITH TIME ZONE;
  v_boost_type TEXT;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id) THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;
  
  IF EXISTS (
    SELECT 1 FROM public.track_promotions 
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Трек уже продвигается');
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
    ELSE RETURN json_build_object('success', false, 'error', 'Неверная длительность');
  END CASE;
  
  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;
  
  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Услуга не найдена');
  END IF;
  
  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id;
  
  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
  END IF;
  
  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id;
  
  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;
  
  UPDATE public.track_promotions 
  SET is_active = false 
  WHERE track_id = p_track_id;
  
  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, v_boost_type, v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;
  
  INSERT INTO public.payments (user_id, amount, status, description, payment_system)
  VALUES (v_user_id, -v_price, 'completed', 'Продвижение трека на ' || p_boost_duration_hours || ' ч.', 'balance');
  
  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', v_price
  );
END;
$$;

-- 3. RPC инкремента impressions_count и clicks_count
CREATE OR REPLACE FUNCTION public.increment_promotion_impression(p_promotion_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.track_promotions
  SET impressions_count = impressions_count + 1
  WHERE id = p_promotion_id AND is_active = true AND expires_at > now();
END;
$$;

CREATE OR REPLACE FUNCTION public.increment_promotion_click(p_promotion_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.track_promotions
  SET clicks_count = clicks_count + 1
  WHERE id = p_promotion_id AND is_active = true AND expires_at > now();
END;
$$;

-- 4. Admin RPC: остановка промо
CREATE OR REPLACE FUNCTION public.admin_stop_promotion(p_promotion_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RETURN json_build_object('success', false, 'error', 'Доступ запрещён');
  END IF;
  
  UPDATE public.track_promotions SET is_active = false WHERE id = p_promotion_id;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Промо не найдено');
  END IF;
  
  RETURN json_build_object('success', true);
END;
$$;

-- 5. Admin RPC: продление промо
CREATE OR REPLACE FUNCTION public.admin_extend_promotion(p_promotion_id UUID, p_hours INTEGER DEFAULT 1)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_row RECORD;
  v_new_expires TIMESTAMP WITH TIME ZONE;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RETURN json_build_object('success', false, 'error', 'Доступ запрещён');
  END IF;
  
  SELECT * INTO v_row FROM public.track_promotions WHERE id = p_promotion_id;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Промо не найдено');
  END IF;
  
  v_new_expires := GREATEST(v_row.expires_at, now()) + (p_hours || ' hours')::INTERVAL;
  
  UPDATE public.track_promotions 
  SET expires_at = v_new_expires, is_active = true 
  WHERE id = p_promotion_id;
  
  RETURN json_build_object('success', true, 'expires_at', v_new_expires);
END;
$$;

-- 6. Admin RPC: список всех промо (для админки)
CREATE OR REPLACE FUNCTION public.admin_get_all_promotions(
  p_active_only BOOLEAN DEFAULT false,
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  id UUID,
  track_id UUID,
  track_title TEXT,
  user_id UUID,
  username TEXT,
  boost_type TEXT,
  price_paid NUMERIC,
  starts_at TIMESTAMP WITH TIME ZONE,
  expires_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN,
  impressions_count INTEGER,
  clicks_count INTEGER,
  created_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role IN ('admin', 'super_admin')) THEN
    RETURN;
  END IF;
  
  RETURN QUERY
  SELECT 
    tp.id,
    tp.track_id,
    t.title AS track_title,
    tp.user_id,
    p.username,
    tp.boost_type,
    COALESCE(tp.price_paid, 0)::NUMERIC AS price_paid,
    COALESCE(tp.starts_at, tp.created_at) AS starts_at,
    tp.expires_at,
    tp.is_active,
    COALESCE(tp.impressions_count, 0)::INTEGER AS impressions_count,
    COALESCE(tp.clicks_count, 0)::INTEGER AS clicks_count,
    tp.created_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  LEFT JOIN public.profiles p ON p.user_id = tp.user_id
  WHERE (NOT p_active_only OR (tp.is_active = true AND tp.expires_at > now()))
  ORDER BY tp.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION public.deactivate_expired_promotions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_promotion_impression(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_promotion_click(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_promotion_impression(UUID) TO anon;
GRANT EXECUTE ON FUNCTION public.increment_promotion_click(UUID) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_stop_promotion(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_extend_promotion(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_all_promotions(BOOLEAN, INTEGER, INTEGER) TO authenticated;
