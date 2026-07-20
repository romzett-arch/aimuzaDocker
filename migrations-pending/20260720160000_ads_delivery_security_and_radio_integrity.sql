-- Advertising delivery v2: trusted server decisions, idempotent events and
-- atomic radio skips. Additive only: legacy RPCs remain for rollback safety,
-- but the API gateway no longer exposes them to clients.

BEGIN;

ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_campaign_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_creatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_targeting ENABLE ROW LEVEL SECURITY;

-- New writes must satisfy the canonical v2 invariants. NOT VALID keeps the
-- migration safe in the presence of unknown historical rows.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ad_creatives_campaign_v2_fkey') THEN
    ALTER TABLE public.ad_creatives
      ADD CONSTRAINT ad_creatives_campaign_v2_fkey
      FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id)
      ON DELETE CASCADE NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ad_campaigns_status_v2_check') THEN
    ALTER TABLE public.ad_campaigns
      ADD CONSTRAINT ad_campaigns_status_v2_check
      CHECK (status IN ('draft', 'active', 'paused', 'completed', 'archived')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ad_campaigns_limits_v2_check') THEN
    ALTER TABLE public.ad_campaigns
      ADD CONSTRAINT ad_campaigns_limits_v2_check
      CHECK (
        (budget_total IS NULL OR budget_total >= 0)
        AND (budget_daily IS NULL OR budget_daily >= 0)
        AND COALESCE(priority, 50) BETWEEN 1 AND 100
        AND (end_date IS NULL OR start_date IS NULL OR end_date > start_date)
      ) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ad_targeting_ranges_v2_check') THEN
    ALTER TABLE public.ad_targeting
      ADD CONSTRAINT ad_targeting_ranges_v2_check
      CHECK (
        (show_hours_start IS NULL OR show_hours_start BETWEEN 0 AND 23)
        AND (show_hours_end IS NULL OR show_hours_end BETWEEN 0 AND 23)
        AND (min_generations IS NULL OR min_generations >= 0)
        AND (max_generations IS NULL OR max_generations >= 0)
        AND (min_generations IS NULL OR max_generations IS NULL OR max_generations >= min_generations)
        AND (min_days_registered IS NULL OR min_days_registered >= 0)
      ) NOT VALID;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.ad_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID REFERENCES public.ad_campaigns(id) ON DELETE SET NULL,
  creative_id UUID REFERENCES public.ad_creatives(id) ON DELETE SET NULL,
  slot_id UUID REFERENCES public.ad_slots(id) ON DELETE SET NULL,
  user_id UUID,
  session_id TEXT NOT NULL,
  device_type TEXT NOT NULL DEFAULT 'desktop',
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 minutes'),
  impression_id UUID REFERENCES public.ad_impressions(id) ON DELETE SET NULL,
  impression_recorded_at TIMESTAMPTZ,
  click_recorded_at TIMESTAMPTZ,
  view_duration_ms INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT ad_deliveries_device_check CHECK (device_type IN ('mobile', 'desktop', 'tablet')),
  CONSTRAINT ad_deliveries_session_check CHECK (char_length(session_id) BETWEEN 8 AND 200),
  CONSTRAINT ad_deliveries_duration_check CHECK (view_duration_ms BETWEEN 0 AND 3600000)
);

ALTER TABLE public.ad_deliveries ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_ad_deliveries_user_issued
  ON public.ad_deliveries(user_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_ad_deliveries_session_issued
  ON public.ad_deliveries(session_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_ad_deliveries_campaign_issued
  ON public.ad_deliveries(campaign_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_ad_impressions_viewed_at
  ON public.ad_impressions(viewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_ad_campaign_slots_slot_campaign
  ON public.ad_campaign_slots(slot_id, campaign_id);

INSERT INTO public.ad_settings(key, value, description) VALUES
  ('ad_free_price', '299', 'Цена отключения рекламы в рублях'),
  ('ad_free_duration_days', '30', 'Срок отключения рекламы в днях'),
  ('premium_no_ads', 'false', 'Не показывать рекламу активным подписчикам'),
  ('max_ads_per_session', '10', 'Максимум показов за браузерную сессию'),
  ('ad_cooldown_seconds', '300', 'Пауза между полноэкранными объявлениями'),
  ('ad_timezone', 'Europe/Moscow', 'Часовой пояс расписания рекламы')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_public_ad_settings()
RETURNS TABLE(key TEXT, value TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.key, s.value
  FROM public.ad_settings s
  WHERE s.key IN (
    'ads_enabled', 'ad_free_price', 'ad_free_duration_days',
    'premium_no_ads', 'max_ads_per_session', 'max_ads_per_hour',
    'ad_cooldown_seconds', 'ad_timezone'
  );
$$;

CREATE OR REPLACE FUNCTION public.request_ad_for_slot(
  p_slot_key TEXT,
  p_device_type TEXT DEFAULT 'desktop',
  p_session_id TEXT DEFAULT NULL
)
RETURNS TABLE(
  delivery_id UUID,
  campaign_id UUID,
  creative_id UUID,
  campaign_name TEXT,
  campaign_type TEXT,
  creative_type TEXT,
  title TEXT,
  subtitle TEXT,
  cta_text TEXT,
  click_url TEXT,
  media_url TEXT,
  media_type TEXT,
  thumbnail_url TEXT,
  external_video_url TEXT,
  internal_type TEXT,
  internal_id TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_slot public.ad_slots%ROWTYPE;
  v_candidate RECORD;
  v_ads_enabled BOOLEAN := true;
  v_max_per_hour INTEGER := 20;
  v_timezone TEXT := 'Europe/Moscow';
  v_now_local TIMESTAMP;
  v_hour INTEGER;
  v_dow INTEGER;
  v_recent_count INTEGER := 0;
BEGIN
  IF p_session_id IS NULL OR char_length(p_session_id) NOT BETWEEN 8 AND 200 THEN
    RETURN;
  END IF;
  IF p_device_type NOT IN ('mobile', 'desktop', 'tablet') THEN
    RETURN;
  END IF;

  SELECT COALESCE(s.value::boolean, true) INTO v_ads_enabled
  FROM public.ad_settings s WHERE s.key = 'ads_enabled';
  IF NOT COALESCE(v_ads_enabled, true) THEN RETURN; END IF;

  SELECT * INTO v_slot
  FROM public.ad_slots s
  WHERE s.slot_key = p_slot_key
    AND COALESCE(s.is_enabled, s.is_active, true)
  LIMIT 1;
  IF v_slot.id IS NULL THEN RETURN; END IF;

  IF v_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = v_user_id AND p.ad_free_until > now()
    ) THEN RETURN; END IF;

    IF EXISTS (
      SELECT 1 FROM public.ad_settings s
      WHERE s.key = 'premium_no_ads' AND s.value = 'true'
    ) AND EXISTS (
      SELECT 1
      FROM public.user_subscriptions us
      LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
      WHERE us.user_id = v_user_id
        AND us.status IN ('active', 'canceled')
        AND us.current_period_end > now()
        AND COALESCE(sp.ad_free, true)
    ) THEN RETURN; END IF;
  END IF;

  SELECT COALESCE(s.value::integer, 20) INTO v_max_per_hour
  FROM public.ad_settings s WHERE s.key = 'max_ads_per_hour';

  SELECT count(*) INTO v_recent_count
  FROM public.ad_deliveries d
  WHERE d.impression_recorded_at > now() - interval '1 hour'
    AND ((v_user_id IS NOT NULL AND d.user_id = v_user_id)
      OR (v_user_id IS NULL AND d.user_id IS NULL AND d.session_id = p_session_id));
  IF v_recent_count >= GREATEST(COALESCE(v_max_per_hour, 20), 0) THEN RETURN; END IF;

  IF COALESCE(v_slot.frequency_cap, 0) > 0 THEN
    SELECT count(*) INTO v_recent_count
    FROM public.ad_deliveries d
    WHERE d.slot_id = v_slot.id
      AND d.impression_recorded_at > now() - interval '1 hour'
      AND ((v_user_id IS NOT NULL AND d.user_id = v_user_id)
        OR (v_user_id IS NULL AND d.user_id IS NULL AND d.session_id = p_session_id));
    IF v_recent_count >= v_slot.frequency_cap THEN RETURN; END IF;
  END IF;

  IF COALESCE(v_slot.cooldown_seconds, 0) > 0 AND EXISTS (
    SELECT 1 FROM public.ad_deliveries d
    WHERE d.slot_id = v_slot.id
      AND d.impression_recorded_at > now() - make_interval(secs => v_slot.cooldown_seconds)
      AND ((v_user_id IS NOT NULL AND d.user_id = v_user_id)
        OR (v_user_id IS NULL AND d.user_id IS NULL AND d.session_id = p_session_id))
  ) THEN RETURN; END IF;

  SELECT COALESCE(s.value, 'Europe/Moscow') INTO v_timezone
  FROM public.ad_settings s WHERE s.key = 'ad_timezone';
  BEGIN
    v_now_local := now() AT TIME ZONE COALESCE(v_timezone, 'Europe/Moscow');
  EXCEPTION WHEN invalid_parameter_value THEN
    v_now_local := now() AT TIME ZONE 'Europe/Moscow';
  END;
  v_hour := EXTRACT(HOUR FROM v_now_local);
  v_dow := EXTRACT(ISODOW FROM v_now_local);

  SELECT
    c.id AS campaign_id,
    cr.id AS creative_id,
    c.name AS campaign_name,
    COALESCE(c.campaign_type, 'external') AS campaign_type,
    COALESCE(cr.creative_type, cr.type, 'image') AS creative_type,
    cr.title,
    COALESCE(cr.subtitle, cr.description) AS subtitle,
    COALESCE(cr.cta_text, 'Подробнее') AS cta_text,
    COALESCE(cr.click_url, c.link_url) AS click_url,
    COALESCE(cr.media_url, c.image_url) AS media_url,
    cr.media_type,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id::text AS internal_id
  INTO v_candidate
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id AND t.target_type IS NULL
  WHERE c.status = 'active'
    AND cs.slot_id = v_slot.id
    AND COALESCE(cs.is_active, true)
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    AND (c.budget_total IS NULL OR COALESCE(c.impressions_count, c.impressions, 0) < c.budget_total)
    AND (c.budget_daily IS NULL OR (
      SELECT count(*) FROM public.ad_impressions ai
      WHERE ai.campaign_id = c.id
        AND ai.viewed_at >= date_trunc('day', now() AT TIME ZONE COALESCE(v_timezone, 'Europe/Moscow')) AT TIME ZONE COALESCE(v_timezone, 'Europe/Moscow')
    ) < c.budget_daily)
    AND (v_slot.supported_types IS NULL OR cardinality(v_slot.supported_types) = 0
      OR COALESCE(cr.creative_type, cr.type, 'image') = ANY(v_slot.supported_types))
    AND (t.id IS NULL
      OR (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type IN ('desktop', 'tablet') AND COALESCE(t.target_desktop, true)))
    AND (t.id IS NULL OR t.show_hours_start IS NULL OR t.show_hours_end IS NULL OR
      CASE WHEN t.show_hours_start <= t.show_hours_end
        THEN v_hour >= t.show_hours_start AND v_hour < t.show_hours_end
        ELSE v_hour >= t.show_hours_start OR v_hour < t.show_hours_end END)
    AND (t.id IS NULL OR t.show_days_of_week IS NULL OR v_dow = ANY(t.show_days_of_week))
    AND (t.id IS NULL
      OR (COALESCE(t.target_free_users, true) AND COALESCE(t.target_subscribed_users, true))
      OR (COALESCE(t.target_free_users, false) AND NOT EXISTS (
        SELECT 1 FROM public.user_subscriptions us
        WHERE us.user_id = v_user_id AND us.status IN ('active', 'canceled') AND us.current_period_end > now()))
      OR (COALESCE(t.target_subscribed_users, false) AND EXISTS (
        SELECT 1 FROM public.user_subscriptions us
        WHERE us.user_id = v_user_id AND us.status IN ('active', 'canceled') AND us.current_period_end > now())))
    AND (t.id IS NULL OR t.min_generations IS NULL OR v_user_id IS NULL
      OR (SELECT count(*) FROM public.tracks tr WHERE tr.user_id = v_user_id) >= t.min_generations)
    AND (t.id IS NULL OR t.max_generations IS NULL OR v_user_id IS NULL
      OR (SELECT count(*) FROM public.tracks tr WHERE tr.user_id = v_user_id) <= t.max_generations)
    AND (t.id IS NULL OR t.min_days_registered IS NULL OR v_user_id IS NULL
      OR (SELECT EXTRACT(DAY FROM v_now_local - (p.created_at AT TIME ZONE COALESCE(v_timezone, 'Europe/Moscow')))
          FROM public.profiles p WHERE p.user_id = v_user_id) >= t.min_days_registered)
  ORDER BY COALESCE(cs.priority_override, cs.priority, c.priority, 50) DESC, random()
  LIMIT 1;

  IF v_candidate.campaign_id IS NULL THEN RETURN; END IF;

  INSERT INTO public.ad_deliveries(campaign_id, creative_id, slot_id, user_id, session_id, device_type)
  VALUES (v_candidate.campaign_id, v_candidate.creative_id, v_slot.id, v_user_id, p_session_id, p_device_type)
  RETURNING id INTO delivery_id;

  campaign_id := v_candidate.campaign_id;
  creative_id := v_candidate.creative_id;
  campaign_name := v_candidate.campaign_name;
  campaign_type := v_candidate.campaign_type;
  creative_type := v_candidate.creative_type;
  title := v_candidate.title;
  subtitle := v_candidate.subtitle;
  cta_text := v_candidate.cta_text;
  click_url := v_candidate.click_url;
  media_url := v_candidate.media_url;
  media_type := v_candidate.media_type;
  thumbnail_url := v_candidate.thumbnail_url;
  external_video_url := v_candidate.external_video_url;
  internal_type := v_candidate.internal_type;
  internal_id := v_candidate.internal_id;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_impression_v2(
  p_delivery_id UUID,
  p_session_id TEXT,
  p_page_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delivery public.ad_deliveries%ROWTYPE;
  v_impression_id UUID;
  v_total_limit INTEGER;
  v_daily_limit INTEGER;
BEGIN
  SELECT * INTO v_delivery FROM public.ad_deliveries
  WHERE id = p_delivery_id FOR UPDATE;
  IF v_delivery.id IS NULL OR v_delivery.session_id <> p_session_id
    OR v_delivery.expires_at <= now() THEN RETURN NULL; END IF;
  IF v_delivery.user_id IS DISTINCT FROM auth.uid() THEN RETURN NULL; END IF;
  IF v_delivery.impression_id IS NOT NULL THEN RETURN v_delivery.impression_id; END IF;

  SELECT c.budget_total, c.budget_daily INTO v_total_limit, v_daily_limit
  FROM public.ad_campaigns c
  WHERE c.id = v_delivery.campaign_id AND c.status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_total_limit IS NOT NULL AND (
    SELECT count(*) FROM public.ad_impressions ai WHERE ai.campaign_id = v_delivery.campaign_id
  ) >= v_total_limit THEN RETURN NULL; END IF;
  IF v_daily_limit IS NOT NULL AND (
    SELECT count(*) FROM public.ad_impressions ai
    WHERE ai.campaign_id = v_delivery.campaign_id AND ai.viewed_at >= date_trunc('day', now())
  ) >= v_daily_limit THEN RETURN NULL; END IF;

  INSERT INTO public.ad_impressions(
    campaign_id, creative_id, slot_id, user_id, device_type,
    page_url, viewed_at, session_id
  ) VALUES (
    v_delivery.campaign_id, v_delivery.creative_id, v_delivery.slot_id,
    v_delivery.user_id, v_delivery.device_type, left(p_page_url, 1000), now(), p_session_id
  ) RETURNING id INTO v_impression_id;

  UPDATE public.ad_deliveries
  SET impression_id = v_impression_id, impression_recorded_at = now()
  WHERE id = p_delivery_id;

  UPDATE public.ad_campaigns
  SET impressions_count = COALESCE(impressions_count, 0) + 1,
      impressions = COALESCE(impressions, 0) + 1,
      updated_at = now()
  WHERE id = v_delivery.campaign_id;
  RETURN v_impression_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_click_v2(
  p_delivery_id UUID,
  p_session_id TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delivery public.ad_deliveries%ROWTYPE;
BEGIN
  SELECT * INTO v_delivery FROM public.ad_deliveries
  WHERE id = p_delivery_id FOR UPDATE;
  IF v_delivery.id IS NULL OR v_delivery.session_id <> p_session_id
    OR v_delivery.user_id IS DISTINCT FROM auth.uid()
    OR v_delivery.impression_id IS NULL OR v_delivery.click_recorded_at IS NOT NULL
  THEN RETURN false; END IF;

  UPDATE public.ad_impressions
  SET clicked_at = COALESCE(clicked_at, now()), is_click = true
  WHERE id = v_delivery.impression_id AND clicked_at IS NULL;
  IF NOT FOUND THEN RETURN false; END IF;

  UPDATE public.ad_deliveries SET click_recorded_at = now() WHERE id = p_delivery_id;
  UPDATE public.ad_campaigns
  SET clicks_count = COALESCE(clicks_count, 0) + 1,
      clicks = COALESCE(clicks, 0) + 1,
      updated_at = now()
  WHERE id = v_delivery.campaign_id;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_view_duration_v2(
  p_delivery_id UUID,
  p_session_id TEXT,
  p_duration_ms INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delivery public.ad_deliveries%ROWTYPE;
  v_duration INTEGER := LEAST(GREATEST(COALESCE(p_duration_ms, 0), 0), 3600000);
BEGIN
  SELECT * INTO v_delivery FROM public.ad_deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF v_delivery.id IS NULL OR v_delivery.session_id <> p_session_id
    OR v_delivery.user_id IS DISTINCT FROM auth.uid()
    OR v_delivery.impression_id IS NULL THEN RETURN false; END IF;
  UPDATE public.ad_deliveries
  SET view_duration_ms = GREATEST(view_duration_ms, v_duration)
  WHERE id = p_delivery_id;
  UPDATE public.ad_impressions
  SET view_duration_ms = GREATEST(COALESCE(view_duration_ms, 0), v_duration)
  WHERE id = v_delivery.impression_id;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_ad_campaign_slots(
  p_campaign_id UUID,
  p_slot_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role::text IN ('admin', 'super_admin')
  ) THEN RAISE EXCEPTION 'administrator access required' USING ERRCODE = '42501'; END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_slot_ids, ARRAY[]::UUID[])) sid
    LEFT JOIN public.ad_slots s ON s.id = sid
    WHERE s.id IS NULL
  ) THEN RAISE EXCEPTION 'unknown advertising slot' USING ERRCODE = '23503'; END IF;

  DELETE FROM public.ad_campaign_slots WHERE campaign_id = p_campaign_id;
  INSERT INTO public.ad_campaign_slots(campaign_id, slot_id, is_active)
  SELECT p_campaign_id, sid, true
  FROM (SELECT DISTINCT unnest(COALESCE(p_slot_ids, ARRAY[]::UUID[])) AS sid) x;
END;
$$;

CREATE TABLE IF NOT EXISTS public.radio_ad_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ad_id UUID NOT NULL REFERENCES public.radio_ad_placements(id) ON DELETE CASCADE,
  break_id UUID NOT NULL,
  session_id TEXT NOT NULL,
  user_id UUID,
  event_type TEXT NOT NULL CHECK (event_type IN ('started', 'completed', 'skip')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (break_id, session_id, event_type)
);
ALTER TABLE public.radio_ad_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_radio_ad_events_ad_created
  ON public.radio_ad_events(ad_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.radio_record_ad_event(
  p_ad_id UUID,
  p_break_id UUID,
  p_session_id TEXT,
  p_event_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_inserted UUID;
BEGIN
  IF p_event_type NOT IN ('started', 'completed')
    OR char_length(COALESCE(p_session_id, '')) NOT BETWEEN 8 AND 200 THEN RETURN false; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.radio_ad_placements p
    WHERE p.id = p_ad_id AND p.is_active
      AND (p.starts_at IS NULL OR p.starts_at <= now())
      AND (p.ends_at IS NULL OR p.ends_at > now())
  ) THEN RETURN false; END IF;

  INSERT INTO public.radio_ad_events(ad_id, break_id, session_id, user_id, event_type)
  VALUES (p_ad_id, p_break_id, p_session_id, auth.uid(), p_event_type)
  ON CONFLICT (break_id, session_id, event_type) DO NOTHING
  RETURNING id INTO v_inserted;
  IF v_inserted IS NULL THEN RETURN true; END IF;
  IF p_event_type = 'started' THEN
    UPDATE public.radio_ad_placements SET impressions = COALESCE(impressions, 0) + 1 WHERE id = p_ad_id;
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.radio_skip_ad_v2(
  p_ad_id UUID,
  p_break_id UUID,
  p_session_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_skip_price INTEGER := 5;
  v_balance INTEGER;
  v_event_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  IF char_length(COALESCE(p_session_id, '')) NOT BETWEEN 8 AND 200 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_session');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.radio_ad_placements p
    WHERE p.id = p_ad_id AND p.is_active
      AND (p.starts_at IS NULL OR p.starts_at <= now())
      AND (p.ends_at IS NULL OR p.ends_at > now())
  ) THEN RETURN jsonb_build_object('ok', false, 'error', 'ad_not_active'); END IF;

  SELECT COALESCE((rc.value->>'skip_ad_price_rub')::integer,
                  (rc.value->>'skip_price_rub')::integer, 5)
  INTO v_skip_price FROM public.radio_config rc WHERE rc.key = 'advertising';
  v_skip_price := GREATEST(COALESCE(v_skip_price, 5), 0);

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = v_user_id FOR UPDATE;
  IF v_balance IS NULL OR v_balance < v_skip_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  INSERT INTO public.radio_ad_events(ad_id, break_id, session_id, user_id, event_type)
  VALUES (p_ad_id, p_break_id, p_session_id, v_user_id, 'skip')
  ON CONFLICT (break_id, session_id, event_type) DO NOTHING
  RETURNING id INTO v_event_id;
  IF v_event_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'already_processed', true, 'charged', 0);
  END IF;

  UPDATE public.profiles SET balance = balance - v_skip_price WHERE user_id = v_user_id;
  UPDATE public.radio_ad_placements SET clicks = COALESCE(clicks, 0) + 1 WHERE id = p_ad_id;
  INSERT INTO public.balance_transactions(
    user_id, amount, type, description, reference_type, reference_id,
    balance_before, balance_after, metadata
  ) VALUES (
    v_user_id, -v_skip_price, 'radio_skip',
    'Пропуск рекламы: ' || v_skip_price || ' ₽', 'radio_ad', p_ad_id,
    v_balance, v_balance - v_skip_price,
    jsonb_build_object('break_id', p_break_id, 'session_id', p_session_id)
  );
  RETURN jsonb_build_object('ok', true, 'charged', v_skip_price, 'balance_after', v_balance - v_skip_price);
END;
$$;

COMMIT;
