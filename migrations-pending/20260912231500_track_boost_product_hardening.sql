-- Track boost product hardening:
-- atomic purchase, server-owned eligibility/quota state and deduplicated analytics.

ALTER TABLE public.track_promotions
  ADD COLUMN IF NOT EXISTS shelf_impressions_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS feed_impressions_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS radio_impressions_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS opens_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS plays_count INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_track_promotions_track_active_expiry
  ON public.track_promotions (track_id, is_active, expires_at DESC);

CREATE INDEX IF NOT EXISTS idx_track_promotions_user_free_created
  ON public.track_promotions (user_id, created_at DESC)
  WHERE price_paid = 0;

CREATE TABLE IF NOT EXISTS public.track_promotion_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promotion_id UUID NOT NULL REFERENCES public.track_promotions(id) ON DELETE CASCADE,
  user_id UUID,
  visitor_key TEXT NOT NULL CHECK (char_length(visitor_key) BETWEEN 8 AND 128),
  event_type TEXT NOT NULL CHECK (event_type IN ('impression', 'open', 'play')),
  surface TEXT NOT NULL CHECK (surface IN ('shelf', 'feed', 'track', 'radio')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (promotion_id, visitor_key, event_type, surface)
);

CREATE INDEX IF NOT EXISTS idx_track_promotion_events_promotion_created
  ON public.track_promotion_events (promotion_id, created_at DESC);

ALTER TABLE public.track_promotion_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.track_promotion_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_track_promotion_event(
  p_track_id UUID,
  p_event_type TEXT,
  p_surface TEXT,
  p_visitor_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_promotion_id UUID;
  v_event_id UUID;
BEGIN
  IF p_event_type NOT IN ('impression', 'open', 'play') THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_event_type');
  END IF;

  IF p_surface NOT IN ('shelf', 'feed', 'track', 'radio') THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_surface');
  END IF;

  IF p_visitor_key IS NULL OR char_length(p_visitor_key) NOT BETWEEN 8 AND 128 THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_visitor_key');
  END IF;

  SELECT tp.id
  INTO v_promotion_id
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE tp.track_id = p_track_id
    AND tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
    AND COALESCE(t.is_in_my_releases, false) = false
  ORDER BY tp.expires_at DESC
  LIMIT 1;

  IF v_promotion_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'promotion_not_active');
  END IF;

  INSERT INTO public.track_promotion_events (
    promotion_id, user_id, visitor_key, event_type, surface
  )
  VALUES (
    v_promotion_id, auth.uid(), p_visitor_key, p_event_type, p_surface
  )
  ON CONFLICT (promotion_id, visitor_key, event_type, surface) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'duplicate', true);
  END IF;

  UPDATE public.track_promotions
  SET
    impressions_count = COALESCE(impressions_count, 0)
      + CASE WHEN p_event_type = 'impression' THEN 1 ELSE 0 END,
    clicks_count = COALESCE(clicks_count, 0)
      + CASE WHEN p_event_type IN ('open', 'play') THEN 1 ELSE 0 END,
    shelf_impressions_count = shelf_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'shelf' THEN 1 ELSE 0 END,
    feed_impressions_count = feed_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'feed' THEN 1 ELSE 0 END,
    radio_impressions_count = radio_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'radio' THEN 1 ELSE 0 END,
    opens_count = opens_count
      + CASE WHEN p_event_type = 'open' THEN 1 ELSE 0 END,
    plays_count = plays_count
      + CASE WHEN p_event_type = 'play' THEN 1 ELSE 0 END
  WHERE id = v_promotion_id;

  RETURN jsonb_build_object('recorded', true, 'promotion_id', v_promotion_id);
END;
$$;

REVOKE ALL ON FUNCTION public.record_track_promotion_event(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_track_promotion_event(UUID, TEXT, TEXT, TEXT) TO anon, authenticated;

-- Legacy counter RPCs accepted a public promotion UUID and had no deduplication.
REVOKE ALL ON FUNCTION public.increment_promotion_impression(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.increment_promotion_click(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_boosted_tracks(p_limit INTEGER DEFAULT 5)
RETURNS TABLE (
  track_id UUID,
  promotion_id UUID,
  boost_type TEXT,
  expires_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT tp.track_id, tp.id, tp.boost_type, tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
    AND t.audio_url IS NOT NULL
    AND COALESCE(t.is_in_my_releases, false) = false
  -- A stable five-minute shuffle gives every paid promotion shelf exposure.
  ORDER BY md5(
    tp.id::TEXT || ':' ||
    floor(extract(epoch FROM now()) / 300)::BIGINT::TEXT
  )
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 5), 20));
$$;

REVOKE ALL ON FUNCTION public.get_boosted_tracks(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_track_boost_state(p_track_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_track RECORD;
  v_active JSONB;
  v_last JSONB;
  v_free_total INTEGER := 0;
  v_free_used INTEGER := 0;
  v_free_duration INTEGER := 0;
  v_day_start TIMESTAMPTZ;
  v_day_end TIMESTAMPTZ;
  v_eligible BOOLEAN := true;
  v_eligibility_error TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;

  SELECT id, title, is_public, status, is_in_my_releases, audio_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id AND user_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;

  IF NOT COALESCE(v_track.is_public, false) THEN
    v_eligible := false;
    v_eligibility_error := 'Сначала опубликуйте трек';
  ELSIF v_track.status IS DISTINCT FROM 'completed' THEN
    v_eligible := false;
    v_eligibility_error := 'Дождитесь завершения обработки трека';
  ELSIF v_track.audio_url IS NULL OR btrim(v_track.audio_url) = '' THEN
    v_eligible := false;
    v_eligibility_error := 'У трека отсутствует аудиофайл';
  ELSIF COALESCE(v_track.is_in_my_releases, false) THEN
    v_eligible := false;
    v_eligibility_error := 'Трек из раздела «Мои релизы» нельзя продвигать внутри проекта';
  END IF;

  v_day_start := date_trunc('day', now() AT TIME ZONE 'Europe/Moscow') AT TIME ZONE 'Europe/Moscow';
  v_day_end := (date_trunc('day', now() AT TIME ZONE 'Europe/Moscow') + interval '1 day') AT TIME ZONE 'Europe/Moscow';

  SELECT COALESCE(sp.boosts_per_day, 0), COALESCE(sp.boost_duration_hours, 0)
  INTO v_free_total, v_free_duration
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = v_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  v_free_total := COALESCE(v_free_total, 0);
  v_free_duration := COALESCE(v_free_duration, 0);

  SELECT COUNT(*)::INTEGER
  INTO v_free_used
  FROM public.track_promotions
  WHERE user_id = v_user_id
    AND price_paid = 0
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT jsonb_build_object(
    'id', tp.id,
    'boost_type', tp.boost_type,
    'starts_at', COALESCE(tp.starts_at, tp.created_at),
    'expires_at', tp.expires_at,
    'price_paid', tp.price_paid,
    'impressions', COALESCE(tp.impressions_count, 0),
    'shelf_impressions', COALESCE(tp.shelf_impressions_count, 0),
    'feed_impressions', COALESCE(tp.feed_impressions_count, 0),
    'radio_impressions', COALESCE(tp.radio_impressions_count, 0),
    'opens', COALESCE(tp.opens_count, 0),
    'plays', COALESCE(tp.plays_count, 0)
  )
  INTO v_active
  FROM public.track_promotions tp
  WHERE tp.track_id = p_track_id
    AND tp.is_active = true
    AND tp.expires_at > now()
  ORDER BY tp.expires_at DESC
  LIMIT 1;

  SELECT jsonb_build_object(
    'id', tp.id,
    'boost_type', tp.boost_type,
    'starts_at', COALESCE(tp.starts_at, tp.created_at),
    'expires_at', tp.expires_at,
    'price_paid', tp.price_paid,
    'impressions', COALESCE(tp.impressions_count, 0),
    'shelf_impressions', COALESCE(tp.shelf_impressions_count, 0),
    'feed_impressions', COALESCE(tp.feed_impressions_count, 0),
    'radio_impressions', COALESCE(tp.radio_impressions_count, 0),
    'opens', COALESCE(tp.opens_count, 0),
    'plays', COALESCE(tp.plays_count, 0)
  )
  INTO v_last
  FROM public.track_promotions tp
  WHERE tp.track_id = p_track_id
  ORDER BY tp.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'eligible', v_eligible,
    'eligibility_error', v_eligibility_error,
    'active_promotion', v_active,
    'last_promotion', v_last,
    'free_boosts_total', v_free_total,
    'free_boosts_used', v_free_used,
    'free_boosts_remaining', GREATEST(0, v_free_total - v_free_used),
    'free_boost_duration_hours', v_free_duration,
    'resets_at', v_day_end,
    'server_now', now(),
    'prices', jsonb_build_object(
      '1', (SELECT price_rub FROM public.addon_services WHERE name = 'boost_track_1h' AND is_active = true),
      '6', (SELECT price_rub FROM public.addon_services WHERE name = 'boost_track_6h' AND is_active = true),
      '24', (SELECT price_rub FROM public.addon_services WHERE name = 'boost_track_24h' AND is_active = true)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_track_boost_state(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_track_boost_state(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER,
  p_use_subscription_boost BOOLEAN
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_track RECORD;
  v_user_balance NUMERIC;
  v_new_balance NUMERIC;
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMPTZ;
  v_boost_type TEXT;
  v_free_boosts INTEGER := 0;
  v_used_boosts_today INTEGER := 0;
  v_sub_duration INTEGER := 0;
  v_day_start TIMESTAMPTZ;
  v_day_end TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;

  -- Serialize purchases for the same track and the same user's daily quota.
  PERFORM pg_advisory_xact_lock(hashtextextended('track-boost:' || p_track_id::TEXT, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('user-boost:' || v_user_id::TEXT, 0));

  SELECT id, title, is_public, status, is_in_my_releases, audio_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;
  IF NOT COALESCE(v_track.is_public, false) THEN
    RETURN json_build_object('success', false, 'error', 'Сначала опубликуйте трек');
  END IF;
  IF v_track.status IS DISTINCT FROM 'completed' THEN
    RETURN json_build_object('success', false, 'error', 'Дождитесь завершения обработки трека');
  END IF;
  IF v_track.audio_url IS NULL OR btrim(v_track.audio_url) = '' THEN
    RETURN json_build_object('success', false, 'error', 'У трека отсутствует аудиофайл');
  END IF;
  IF COALESCE(v_track.is_in_my_releases, false) THEN
    RETURN json_build_object('success', false, 'error', 'Трек из раздела «Мои релизы» нельзя продвигать внутри проекта');
  END IF;

  UPDATE public.track_promotions
  SET is_active = false,
      status = CASE WHEN status = 'active' THEN 'expired' ELSE status END
  WHERE track_id = p_track_id
    AND is_active = true
    AND expires_at <= now();

  IF EXISTS (
    SELECT 1 FROM public.track_promotions
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Трек уже продвигается');
  END IF;

  v_day_start := date_trunc('day', now() AT TIME ZONE 'Europe/Moscow') AT TIME ZONE 'Europe/Moscow';
  v_day_end := (date_trunc('day', now() AT TIME ZONE 'Europe/Moscow') + interval '1 day') AT TIME ZONE 'Europe/Moscow';

  IF p_use_subscription_boost THEN
    SELECT COALESCE(sp.boosts_per_day, 0), COALESCE(sp.boost_duration_hours, 0)
    INTO v_free_boosts, v_sub_duration
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.user_id = v_user_id
      AND us.status IN ('active', 'canceled')
      AND us.current_period_end > now()
    ORDER BY us.created_at DESC
    LIMIT 1;

    v_free_boosts := COALESCE(v_free_boosts, 0);
    v_sub_duration := COALESCE(v_sub_duration, 0);

    IF v_free_boosts <= 0 OR v_sub_duration <= 0 THEN
      RETURN json_build_object('success', false, 'error', 'На вашем тарифе нет бесплатных бустов');
    END IF;

    SELECT COUNT(*)::INTEGER
    INTO v_used_boosts_today
    FROM public.track_promotions
    WHERE user_id = v_user_id
      AND created_at >= v_day_start
      AND created_at < v_day_end
      AND price_paid = 0;

    IF v_used_boosts_today >= v_free_boosts THEN
      RETURN json_build_object('success', false, 'error', 'Бесплатные бусты на сегодня исчерпаны');
    END IF;

    v_price := 0;
    p_boost_duration_hours := v_sub_duration;
  ELSE
    IF p_boost_duration_hours NOT IN (1, 6, 24) THEN
      RETURN json_build_object('success', false, 'error', 'Неверная длительность');
    END IF;

    v_service_name := 'boost_track_' || p_boost_duration_hours || 'h';
    SELECT price_rub INTO v_price
    FROM public.addon_services
    WHERE name = v_service_name AND is_active = true;

    IF v_price IS NULL THEN
      RETURN json_build_object('success', false, 'error', 'Услуга временно недоступна');
    END IF;

    SELECT balance INTO v_user_balance
    FROM public.profiles
    WHERE user_id = v_user_id
    FOR UPDATE;

    IF v_user_balance IS NULL THEN
      RETURN json_build_object('success', false, 'error', 'Профиль пользователя не найден');
    END IF;
    IF v_user_balance < v_price THEN
      RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
    END IF;

    UPDATE public.profiles
    SET balance = balance - v_price
    WHERE user_id = v_user_id
    RETURNING balance INTO v_new_balance;
  END IF;

  v_boost_type := CASE
    WHEN p_boost_duration_hours >= 24 THEN 'top'
    WHEN p_boost_duration_hours >= 6 THEN 'premium'
    ELSE 'standard'
  END;
  v_expires_at := now() + make_interval(hours => p_boost_duration_hours);

  INSERT INTO public.track_promotions (
    track_id, user_id, type, status, amount, starts_at, ends_at,
    expires_at, boost_type, is_active, price_paid
  ) VALUES (
    p_track_id, v_user_id, 'boost', 'active', COALESCE(v_price, 0), now(), v_expires_at,
    v_expires_at, v_boost_type, true, COALESCE(v_price, 0)
  )
  RETURNING id INTO v_promotion_id;

  IF p_use_subscription_boost THEN
    SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id;
    v_new_balance := v_user_balance;
  END IF;

  INSERT INTO public.balance_transactions (
    user_id, amount, type, description, reference_id, reference_type,
    balance_before, balance_after, metadata
  ) VALUES (
    v_user_id,
    -COALESCE(v_price, 0),
    'purchase',
    CASE WHEN p_use_subscription_boost THEN 'Бесплатный буст трека «' ELSE 'Буст трека «' END
      || COALESCE(v_track.title, '—') || '» на ' || p_boost_duration_hours || ' ч.',
    v_promotion_id,
    'promotion',
    v_user_balance,
    v_new_balance,
    jsonb_build_object(
      'track_id', p_track_id,
      'track_title', v_track.title,
      'duration_hours', p_boost_duration_hours,
      'boost_type', v_boost_type,
      'expires_at', v_expires_at,
      'free_boost', p_use_subscription_boost,
      'source', CASE WHEN p_use_subscription_boost THEN 'subscription' ELSE 'balance' END
    )
  );

  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', COALESCE(v_price, 0),
    'free_boost', p_use_subscription_boost,
    'boost_type', v_boost_type
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER DEFAULT 1
)
RETURNS JSON
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.purchase_track_boost(p_track_id, p_boost_duration_hours, false);
$$;

REVOKE ALL ON FUNCTION public.purchase_track_boost(UUID, INTEGER, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purchase_track_boost(UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_track_boost(UUID, INTEGER) TO authenticated;
