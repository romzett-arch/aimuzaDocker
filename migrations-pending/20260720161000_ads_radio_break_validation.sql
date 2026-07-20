-- Bind radio events to short-lived breaks emitted by the radio service and
-- enforce delivery issuance limits inside PostgreSQL as a second line of defence.

BEGIN;

CREATE TABLE IF NOT EXISTS public.radio_ad_breaks (
  id UUID PRIMARY KEY,
  ad_id UUID NOT NULL REFERENCES public.radio_ad_placements(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT radio_ad_breaks_expiry_check CHECK (expires_at > created_at)
);
ALTER TABLE public.radio_ad_breaks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_radio_ad_breaks_expiry ON public.radio_ad_breaks(expires_at);

CREATE OR REPLACE FUNCTION public.enforce_ad_delivery_issue_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_max_session INTEGER := 10;
  v_identity_count INTEGER;
BEGIN
  SELECT COALESCE(value::integer, 10) INTO v_max_session
  FROM public.ad_settings WHERE key = 'max_ads_per_session';

  SELECT count(*) INTO v_identity_count
  FROM public.ad_deliveries d
  WHERE d.impression_recorded_at IS NOT NULL
    AND ((NEW.user_id IS NOT NULL AND d.user_id = NEW.user_id AND d.session_id = NEW.session_id)
      OR (NEW.user_id IS NULL AND d.user_id IS NULL AND d.session_id = NEW.session_id));
  IF v_identity_count >= GREATEST(COALESCE(v_max_session, 10), 0) THEN
    RAISE EXCEPTION 'ad_session_limit_reached' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_identity_count
  FROM public.ad_deliveries d
  WHERE d.issued_at > now() - interval '1 minute'
    AND ((NEW.user_id IS NOT NULL AND d.user_id = NEW.user_id)
      OR (NEW.user_id IS NULL AND d.user_id IS NULL AND d.session_id = NEW.session_id));
  IF v_identity_count >= 30 THEN
    RAISE EXCEPTION 'ad_delivery_rate_limit_reached' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_ad_delivery_issue_limits ON public.ad_deliveries;
CREATE TRIGGER trg_enforce_ad_delivery_issue_limits
BEFORE INSERT ON public.ad_deliveries
FOR EACH ROW EXECUTE FUNCTION public.enforce_ad_delivery_issue_limits();

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
    SELECT 1 FROM public.radio_ad_breaks b
    JOIN public.radio_ad_placements p ON p.id = b.ad_id
    WHERE b.id = p_break_id AND b.ad_id = p_ad_id AND b.expires_at > now()
      AND p.is_active AND (p.starts_at IS NULL OR p.starts_at <= now())
      AND (p.ends_at IS NULL OR p.ends_at > now())
  ) THEN RETURN false; END IF;

  INSERT INTO public.radio_ad_events(ad_id, break_id, session_id, user_id, event_type)
  VALUES (p_ad_id, p_break_id, p_session_id, auth.uid(), p_event_type)
  ON CONFLICT (break_id, session_id, event_type) DO NOTHING
  RETURNING id INTO v_inserted;
  IF v_inserted IS NOT NULL AND p_event_type = 'started' THEN
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
    SELECT 1 FROM public.radio_ad_breaks b
    JOIN public.radio_ad_placements p ON p.id = b.ad_id
    WHERE b.id = p_break_id AND b.ad_id = p_ad_id AND b.expires_at > now()
      AND p.is_active AND (p.starts_at IS NULL OR p.starts_at <= now())
      AND (p.ends_at IS NULL OR p.ends_at > now())
  ) THEN RETURN jsonb_build_object('ok', false, 'error', 'invalid_or_expired_break'); END IF;

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
