BEGIN;

-- Public Hero Banner switch, managed together with advertising.
INSERT INTO public.ad_settings(key, value, description)
VALUES ('hero_banner_enabled', 'true', 'Показывать компактный Hero Banner на главной странице')
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
    'ad_cooldown_seconds', 'ad_timezone', 'hero_banner_enabled'
  );
$$;

-- Advertising tables remain private, with explicit administrator-only access.
DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'ad_campaigns', 'ad_campaign_slots', 'ad_creatives', 'ad_impressions',
    'ad_settings', 'ad_slots', 'ad_targeting', 'ad_deliveries'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Administrators manage ' || v_table, v_table);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()))',
      'Administrators manage ' || v_table, v_table
    );
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', v_table);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION public.get_public_ad_settings() TO anon, authenticated;

-- Fill fields that older installations may not have received because the seed used DO NOTHING.
UPDATE public.radio_config
SET value = value || jsonb_build_object('max_author_share_percent', COALESCE(value->'max_author_share_percent', '15'::jsonb))
WHERE key = 'smart_stream';

-- One validated write gateway for all radio configuration cards.
CREATE OR REPLACE FUNCTION public.admin_update_radio_config(p_key TEXT, p_value JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_result JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'administrator access required' USING ERRCODE = '42501';
  END IF;
  IF p_key NOT IN ('smart_stream', 'listen_to_earn', 'auction', 'predictions', 'advertising')
     OR jsonb_typeof(p_value) <> 'object' THEN
    RAISE EXCEPTION 'unknown or invalid radio configuration';
  END IF;

  IF p_key = 'smart_stream' THEN
    IF (p_value->>'w_quality')::NUMERIC NOT BETWEEN 0 AND 1
      OR (p_value->>'w_xp')::NUMERIC NOT BETWEEN 0 AND 1
      OR (p_value->>'w_stake')::NUMERIC NOT BETWEEN 0 AND 1
      OR (p_value->>'w_freshness')::NUMERIC NOT BETWEEN 0 AND 1
      OR (p_value->>'w_discovery')::NUMERIC NOT BETWEEN 0 AND 1
      OR (p_value->>'min_quality_score')::NUMERIC NOT BETWEEN 0 AND 10000
      OR (p_value->>'min_duration_sec')::INTEGER NOT BETWEEN 1 AND 3600
      OR (p_value->>'discovery_boost_days')::INTEGER NOT BETWEEN 0 AND 365
      OR (p_value->>'discovery_boost_multiplier')::NUMERIC NOT BETWEEN 0 AND 10
      OR COALESCE((p_value->>'max_author_share_percent')::NUMERIC, 15) NOT BETWEEN 1 AND 100
    THEN RAISE EXCEPTION 'smart_stream values are outside allowed ranges'; END IF;
  ELSIF p_key = 'listen_to_earn' THEN
    IF (p_value->>'xp_per_listen')::INTEGER NOT BETWEEN 0 AND 100
      OR (p_value->>'min_listen_percent')::NUMERIC NOT BETWEEN 0 AND 100
      OR (p_value->>'daily_cap')::INTEGER NOT BETWEEN 0 AND 10000
      OR (p_value->>'afk_check_interval_sec')::INTEGER NOT BETWEEN 30 AND 3600
      OR (p_value->>'afk_max_failures')::INTEGER NOT BETWEEN 1 AND 20
    THEN RAISE EXCEPTION 'listen_to_earn values are outside allowed ranges'; END IF;
  ELSIF p_key = 'auction' THEN
    IF jsonb_typeof(p_value->'enabled') <> 'boolean'
      OR (p_value->>'min_bid_rub')::INTEGER NOT BETWEEN 1 AND 1000000
      OR (p_value->>'bid_step_rub')::INTEGER NOT BETWEEN 1 AND 1000000
      OR (p_value->>'slot_duration_minutes')::INTEGER NOT BETWEEN 1 AND 1440
    THEN RAISE EXCEPTION 'auction values are outside allowed ranges'; END IF;
  ELSIF p_key = 'predictions' THEN
    IF (p_value->>'min_bet')::INTEGER NOT BETWEEN 1 AND 1000000
      OR (p_value->>'max_bet')::INTEGER NOT BETWEEN 1 AND 1000000
      OR (p_value->>'min_bet')::INTEGER > (p_value->>'max_bet')::INTEGER
      OR (p_value->>'hit_threshold_likes')::INTEGER NOT BETWEEN 0 AND 1000000
      OR (p_value->>'payout_multiplier')::NUMERIC NOT BETWEEN 1 AND 100
    THEN RAISE EXCEPTION 'prediction values are outside allowed ranges'; END IF;
  ELSIF p_key = 'advertising' THEN
    IF jsonb_typeof(p_value->'enabled') <> 'boolean'
      OR (p_value->>'audio_ad_slot_every_n_tracks')::INTEGER NOT BETWEEN 1 AND 100
      OR COALESCE((p_value->>'skip_ad_price_rub')::NUMERIC, (p_value->>'skip_price_rub')::NUMERIC, 0) NOT BETWEEN 0 AND 1000000
      OR (p_value->>'audio_ad_max_duration_sec')::INTEGER NOT BETWEEN 1 AND 300
    THEN RAISE EXCEPTION 'advertising values are outside allowed ranges'; END IF;
  END IF;

  INSERT INTO public.radio_config(key, value, updated_at)
  VALUES (p_key, p_value, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
  RETURNING value INTO v_result;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_update_radio_config(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_radio_config(TEXT, JSONB) TO authenticated;

-- Temporary administrator commands consumed by the playlist generator.
CREATE TABLE IF NOT EXISTS public.radio_queue_overrides (
  track_id UUID PRIMARY KEY REFERENCES public.tracks(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('next', 'exclude')),
  expires_at TIMESTAMPTZ NOT NULL,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.radio_queue_overrides ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Administrators manage radio queue overrides" ON public.radio_queue_overrides;
CREATE POLICY "Administrators manage radio queue overrides"
ON public.radio_queue_overrides FOR ALL TO authenticated
USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.radio_queue_overrides TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_radio_queue_override(
  p_track_id UUID,
  p_action TEXT,
  p_duration_minutes INTEGER DEFAULT 60
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'administrator access required' USING ERRCODE = '42501';
  END IF;
  IF p_action NOT IN ('next', 'exclude') OR p_duration_minutes NOT BETWEEN 1 AND 10080 THEN
    RAISE EXCEPTION 'invalid queue override';
  END IF;
  INSERT INTO public.radio_queue_overrides(track_id, action, expires_at, created_by)
  VALUES (p_track_id, p_action, now() + make_interval(mins => p_duration_minutes), auth.uid())
  ON CONFLICT (track_id) DO UPDATE
    SET action = EXCLUDED.action, expires_at = EXCLUDED.expires_at,
        created_by = EXCLUDED.created_by, created_at = now();
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_radio_queue_override(UUID, TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_radio_queue_override(UUID, TEXT, INTEGER) TO authenticated;

-- Make every Smart Stream field affect the real worker queue.
CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  track_id UUID, title TEXT, audio_url TEXT, cover_url TEXT, duration INTEGER,
  author_id UUID, author_username TEXT, author_avatar TEXT, author_tier TEXT,
  author_xp INTEGER, genre_name TEXT, chance_score NUMERIC,
  quality_component NUMERIC, xp_component NUMERIC, freshness_component NUMERIC,
  discovery_component NUMERIC, source TEXT, is_boosted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config JSONB;
  v_w_quality NUMERIC; v_w_xp NUMERIC; v_w_stake NUMERIC;
  v_w_freshness NUMERIC; v_w_discovery NUMERIC; v_min_quality NUMERIC;
  v_min_duration INTEGER; v_discovery_days INTEGER; v_discovery_mult NUMERIC;
  v_max_author_pct NUMERIC; v_author_limit INTEGER;
BEGIN
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'smart_stream';
  v_w_quality := COALESCE((v_config->>'w_quality')::NUMERIC, 0.35);
  v_w_xp := COALESCE((v_config->>'w_xp')::NUMERIC, 0.25);
  v_w_stake := COALESCE((v_config->>'w_stake')::NUMERIC, 0.20);
  v_w_freshness := COALESCE((v_config->>'w_freshness')::NUMERIC, 0.15);
  v_w_discovery := COALESCE((v_config->>'w_discovery')::NUMERIC, 0.05);
  v_min_quality := COALESCE((v_config->>'min_quality_score')::NUMERIC, 2.0);
  v_min_duration := COALESCE((v_config->>'min_duration_sec')::INTEGER, 30);
  v_discovery_days := COALESCE((v_config->>'discovery_boost_days')::INTEGER, 14);
  v_discovery_mult := COALESCE((v_config->>'discovery_boost_multiplier')::NUMERIC, 2.5);
  v_max_author_pct := COALESCE((v_config->>'max_author_share_percent')::NUMERIC, 15);
  v_author_limit := GREATEST(1, CEIL(GREATEST(p_limit, 1) * v_max_author_pct / 100.0)::INTEGER);

  DELETE FROM public.radio_queue_overrides WHERE expires_at <= now();

  RETURN QUERY
  WITH scored AS (
    SELECT t.id AS tid, t.title, t.audio_url, t.cover_url, t.duration,
      t.user_id AS aid, p.username, p.avatar_url,
      COALESCE(fus.tier, 'newcomer') AS tier,
      COALESCE(fus.xp_total, 0)::INTEGER AS xp_total, g.name AS genre,
      (1 + COALESCE(t.likes_count, 0) * 0.5 + COALESCE(t.plays_count, 0) * 0.02)::NUMERIC AS q,
      LEAST(1.0, COALESCE(fus.xp_total, 0)::NUMERIC / 500.0) AS xp,
      (CASE WHEN tp.id IS NOT NULL THEN 1.5 ELSE 0.5 END * COALESCE(sp.radio_weight_multiplier, 1.0))::NUMERIC AS stake,
      (1.0 / (1.0 + EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400.0 / 30.0))::NUMERIC AS fresh,
      (CASE WHEN t.created_at > now() - make_interval(days => v_discovery_days) THEN v_discovery_mult ELSE 1.0 END)::NUMERIC AS disc,
      (tp.id IS NOT NULL) AS boosted, ro.action AS override_action
    FROM public.tracks t
    JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.track_promotions tp ON tp.track_id = t.id AND tp.status = 'active'
      AND (tp.expires_at > now() OR tp.ends_at > now())
    LEFT JOIN public.user_subscriptions us ON us.user_id = t.user_id
      AND us.status IN ('active', 'canceled') AND us.current_period_end > now()
    LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
    LEFT JOIN public.radio_queue_overrides ro ON ro.track_id = t.id AND ro.expires_at > now()
    WHERE t.status = 'completed' AND t.is_public = true AND t.audio_url IS NOT NULL
      AND (t.duration IS NULL OR t.duration >= v_min_duration)
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
      AND COALESCE(ro.action, '') <> 'exclude'
  ), ranked AS (
    SELECT s.*, row_number() OVER (
      PARTITION BY s.aid
      ORDER BY (s.q*v_w_quality + s.xp*v_w_xp + s.stake*v_w_stake + s.fresh*v_w_freshness + s.disc*v_w_discovery) DESC
    ) AS author_position
    FROM scored s WHERE s.q >= v_min_quality
  )
  SELECT r.tid, r.title, r.audio_url, r.cover_url, r.duration::INTEGER,
    r.aid, r.username, r.avatar_url, r.tier, r.xp_total, r.genre,
    CASE WHEN r.override_action = 'next' THEN 9999::NUMERIC
      ELSE (r.q*v_w_quality + r.xp*v_w_xp + r.stake*v_w_stake + r.fresh*v_w_freshness + r.disc*v_w_discovery)::NUMERIC END,
    r.q, r.xp, r.fresh, r.disc,
    CASE WHEN r.override_action = 'next' THEN 'manual' WHEN r.boosted THEN 'promotion' ELSE 'algorithm' END,
    r.boosted
  FROM ranked r
  WHERE r.author_position <= v_author_limit
  ORDER BY (r.override_action = 'next') DESC,
    (r.q*v_w_quality + r.xp*v_w_xp + r.stake*v_w_stake + r.fresh*v_w_freshness + r.disc*v_w_discovery) DESC
  LIMIT GREATEST(1, LEAST(p_limit, 500));
END;
$$;

-- L2E values now come from radio_config instead of hard-coded constants.
CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID, p_track_id UUID, p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER, p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL, p_ip_hash TEXT DEFAULT NULL,
  p_is_afk_verified BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config JSONB; v_listen_percent NUMERIC; v_xp_earned INTEGER := 0;
  v_xp_today INTEGER; v_daily_cap INTEGER; v_min_percent NUMERIC;
  v_xp_per_listen NUMERIC; v_arena_vote_cast BOOLEAN := false; v_caller UUID;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NOT NULL AND v_caller <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF v_caller IS NULL AND current_user NOT IN ('aimuza', 'postgres', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'listen_to_earn';
  v_daily_cap := COALESCE((v_config->>'daily_cap')::INTEGER, 100);
  v_min_percent := COALESCE((v_config->>'min_listen_percent')::NUMERIC, 60);
  v_xp_per_listen := COALESCE((v_config->>'xp_per_listen')::NUMERIC, 2);
  p_track_duration_sec := GREATEST(p_track_duration_sec, 1);
  v_listen_percent := LEAST(100, GREATEST(0, p_listen_duration_sec::NUMERIC / p_track_duration_sec * 100));

  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_listen_percent >= v_min_percent AND v_xp_today < v_daily_cap THEN
    v_xp_earned := LEAST(GREATEST(1, round(v_xp_per_listen * v_listen_percent / 100)::INTEGER), v_daily_cap - v_xp_today);
  END IF;

  INSERT INTO public.radio_listens(user_id, track_id, session_id, listen_duration_sec,
    track_duration_sec, listen_percent, xp_earned, reaction, ip_hash, is_afk_verified)
  VALUES (p_user_id, p_track_id, p_session_id, p_listen_duration_sec,
    p_track_duration_sec, v_listen_percent, v_xp_earned, p_reaction, p_ip_hash, p_is_afk_verified);

  IF p_reaction IN ('like', 'love') AND v_listen_percent >= 50 AND p_is_afk_verified THEN
    v_arena_vote_cast := public.cast_radio_vote_for_arena(p_user_id, p_track_id, p_listen_duration_sec);
  END IF;
  IF v_xp_earned > 0 THEN PERFORM public.fn_add_xp(p_user_id, v_xp_earned, 'music', false); END IF;
  v_xp_today := v_xp_today + v_xp_earned;
  RETURN jsonb_build_object('ok', true, 'xp_earned', v_xp_earned,
    'listen_percent', v_listen_percent, 'xp_today', v_xp_today,
    'daily_cap', v_daily_cap,
    'listens_today', (SELECT count(*) FROM public.radio_listens WHERE user_id=p_user_id AND created_at>=CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap, 'arena_vote_cast', v_arena_vote_cast);
END;
$$;

-- Auction settings now control availability, minimum bid, step and slot length.
CREATE OR REPLACE FUNCTION public.radio_create_next_slot()
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_config JSONB; v_max_slot INTEGER; v_open_count INTEGER; v_new_id UUID; v_minutes INTEGER;
BEGIN
  SELECT value INTO v_config FROM public.radio_config WHERE key='auction';
  IF COALESCE((v_config->>'enabled')::BOOLEAN, true) = false THEN RETURN NULL; END IF;
  v_minutes := COALESCE((v_config->>'slot_duration_minutes')::INTEGER, 60);
  SELECT count(*) INTO v_open_count FROM public.radio_slots WHERE status IN ('open','bidding');
  IF v_open_count >= 2 THEN RETURN NULL; END IF;
  SELECT COALESCE(max(slot_number),0) INTO v_max_slot FROM public.radio_slots;
  INSERT INTO public.radio_slots(slot_number,starts_at,ends_at,status)
  VALUES(v_max_slot+1,now(),now()+make_interval(mins=>v_minutes),'open') RETURNING id INTO v_new_id;
  RETURN v_new_id;
END; $$;

CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID, p_slot_id UUID, p_track_id UUID, p_amount INTEGER
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller UUID; v_slot RECORD; v_config JSONB; v_min_bid INTEGER; v_bid_step INTEGER;
  v_highest INTEGER; v_balance INTEGER; v_discount_pct INTEGER := 0; v_effective_amount INTEGER;
  v_old_bid RECORD; v_new_bid_id UUID; v_balance_after_refund INTEGER; v_balance_after_debit INTEGER;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL OR v_caller <> p_user_id THEN RETURN jsonb_build_object('ok',false,'error','forbidden'); END IF;
  SELECT value INTO v_config FROM public.radio_config WHERE key='auction';
  IF COALESCE((v_config->>'enabled')::BOOLEAN,true)=false THEN RETURN jsonb_build_object('ok',false,'error','auction_disabled'); END IF;
  v_min_bid := COALESCE((v_config->>'min_bid_rub')::INTEGER,10);
  v_bid_step := COALESCE((v_config->>'bid_step_rub')::INTEGER,5);
  SELECT * INTO v_slot FROM public.radio_slots WHERE id=p_slot_id FOR UPDATE;
  IF v_slot IS NULL THEN RETURN jsonb_build_object('ok',false,'error','slot_not_found'); END IF;
  IF v_slot.status NOT IN ('open','bidding') OR v_slot.ends_at<=now() THEN RETURN jsonb_build_object('ok',false,'error','slot_not_available'); END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tracks WHERE id=p_track_id AND user_id=p_user_id AND status='completed') THEN
    RETURN jsonb_build_object('ok',false,'error','track_not_available'); END IF;
  SELECT COALESCE(sp.radio_auction_discount_pct,0) INTO v_discount_pct
  FROM public.user_subscriptions us JOIN public.subscription_plans sp ON sp.id=us.plan_id
  WHERE us.user_id=p_user_id AND us.status IN ('active','canceled') AND us.current_period_end>now()
  ORDER BY us.created_at DESC LIMIT 1;
  v_effective_amount := GREATEST(1,(p_amount*(100-COALESCE(v_discount_pct,0))/100)::INTEGER);
  SELECT COALESCE(max(amount),0) INTO v_highest FROM public.radio_bids WHERE slot_id=p_slot_id AND status='active';
  IF p_amount<v_min_bid OR p_amount<v_highest+v_bid_step THEN
    RETURN jsonb_build_object('ok',false,'error','bid_too_low','min_required',GREATEST(v_min_bid,v_highest+v_bid_step)); END IF;
  SELECT id,amount,COALESCE(charged_amount,amount) charged_amount INTO v_old_bid
  FROM public.radio_bids WHERE slot_id=p_slot_id AND user_id=p_user_id AND status='active'
  ORDER BY created_at DESC LIMIT 1;
  IF v_old_bid.id IS NOT NULL THEN
    UPDATE public.profiles SET balance=balance+v_old_bid.charged_amount WHERE user_id=p_user_id RETURNING balance INTO v_balance_after_refund;
    INSERT INTO public.balance_transactions(user_id,amount,balance_before,balance_after,type,description,reference_id,reference_type)
    VALUES(p_user_id,v_old_bid.charged_amount,v_balance_after_refund-v_old_bid.charged_amount,v_balance_after_refund,
      'refund','Возврат предыдущей ставки на слот #'||v_slot.slot_number,v_old_bid.id,'radio_bid');
    UPDATE public.radio_bids SET status='outbid' WHERE id=v_old_bid.id;
  END IF;
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id=p_user_id FOR UPDATE;
  IF v_balance IS NULL OR v_balance<v_effective_amount THEN RETURN jsonb_build_object('ok',false,'error','insufficient_balance'); END IF;
  UPDATE public.profiles SET balance=balance-v_effective_amount WHERE user_id=p_user_id RETURNING balance INTO v_balance_after_debit;
  INSERT INTO public.radio_bids(slot_id,user_id,track_id,amount,charged_amount)
  VALUES(p_slot_id,p_user_id,p_track_id,p_amount,v_effective_amount) RETURNING id INTO v_new_bid_id;
  INSERT INTO public.balance_transactions(user_id,amount,balance_before,balance_after,type,description,reference_id,reference_type,metadata)
  VALUES(p_user_id,-v_effective_amount,v_balance_after_debit+v_effective_amount,v_balance_after_debit,'debit',
    'Ставка '||p_amount||'₽ на слот #'||v_slot.slot_number,v_new_bid_id,'radio_bid',
    jsonb_build_object('slot_id',p_slot_id,'track_id',p_track_id,'bid_amount',p_amount,'effective_cost',v_effective_amount,'discount_pct',COALESCE(v_discount_pct,0)));
  UPDATE public.radio_slots SET status='bidding',total_bids=total_bids+1 WHERE id=p_slot_id;
  RETURN jsonb_build_object('ok',true,'bid_amount',p_amount,'effective_cost',v_effective_amount,'discount_pct',COALESCE(v_discount_pct,0),'slot_id',p_slot_id);
END; $$;

-- Prediction limits, hit threshold and payout now come from the admin config.
CREATE OR REPLACE FUNCTION public.radio_place_prediction(
  p_user_id UUID, p_track_id UUID, p_bet_amount INTEGER, p_predicted_hit BOOLEAN
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_config JSONB; v_min INTEGER; v_max INTEGER; v_balance INTEGER; v_caller UUID; v_prediction_id UUID;
BEGIN
  v_caller:=auth.uid();
  IF v_caller IS NULL OR v_caller<>p_user_id THEN RETURN jsonb_build_object('ok',false,'error','unauthorized'); END IF;
  SELECT value INTO v_config FROM public.radio_config WHERE key='predictions';
  v_min:=COALESCE((v_config->>'min_bet')::INTEGER,5); v_max:=COALESCE((v_config->>'max_bet')::INTEGER,100);
  IF p_bet_amount<v_min OR p_bet_amount>v_max THEN RETURN jsonb_build_object('ok',false,'error','invalid_bet_amount','min',v_min,'max',v_max); END IF;
  IF EXISTS(SELECT 1 FROM public.radio_predictions WHERE user_id=p_user_id AND track_id=p_track_id AND status='pending') THEN
    RETURN jsonb_build_object('ok',false,'error','already_predicted'); END IF;
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id=p_user_id FOR UPDATE;
  IF v_balance IS NULL OR v_balance<p_bet_amount THEN RETURN jsonb_build_object('ok',false,'error','insufficient_balance'); END IF;
  INSERT INTO public.radio_predictions(user_id,track_id,bet_amount,predicted_hit,expires_at)
  VALUES(p_user_id,p_track_id,p_bet_amount,p_predicted_hit,now()+interval '24 hours') RETURNING id INTO v_prediction_id;
  UPDATE public.profiles SET balance=balance-p_bet_amount WHERE user_id=p_user_id;
  INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
  VALUES(p_user_id,-p_bet_amount,'radio_prediction','Ставка на прогноз: '||p_bet_amount||' ₽','radio_prediction',v_prediction_id,v_balance,v_balance-p_bet_amount);
  RETURN jsonb_build_object('ok',true,'bet_amount',p_bet_amount,'predicted_hit',p_predicted_hit,'expires_in_hours',24);
END; $$;

CREATE OR REPLACE FUNCTION public.radio_resolve_predictions()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_config JSONB; v_threshold INTEGER; v_multiplier NUMERIC; v_count INTEGER:=0;
  v_rec RECORD; v_actual_hit BOOLEAN; v_payout INTEGER; v_before INTEGER;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'administrator access required' USING ERRCODE='42501';
  END IF;
  SELECT value INTO v_config FROM public.radio_config WHERE key='predictions';
  v_threshold:=COALESCE((v_config->>'hit_threshold_likes')::INTEGER,5);
  v_multiplier:=COALESCE((v_config->>'payout_multiplier')::NUMERIC,1.8);
  FOR v_rec IN SELECT id,track_id,predicted_hit,bet_amount,user_id FROM public.radio_predictions
    WHERE status='pending' AND expires_at<now() FOR UPDATE SKIP LOCKED
  LOOP
    SELECT COALESCE(likes_count,0)>=v_threshold INTO v_actual_hit FROM public.tracks WHERE id=v_rec.track_id;
    v_actual_hit:=COALESCE(v_actual_hit,false);
    v_payout:=CASE WHEN v_actual_hit=v_rec.predicted_hit THEN round(v_rec.bet_amount*v_multiplier)::INTEGER ELSE 0 END;
    UPDATE public.radio_predictions SET actual_result=v_actual_hit,status=CASE WHEN v_payout>0 THEN 'won' ELSE 'lost' END,payout=v_payout WHERE id=v_rec.id;
    IF v_payout>0 THEN
      SELECT balance INTO v_before FROM public.profiles WHERE user_id=v_rec.user_id FOR UPDATE;
      UPDATE public.profiles SET balance=balance+v_payout WHERE user_id=v_rec.user_id;
      INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
      VALUES(v_rec.user_id,v_payout,'radio_win','Выигрыш прогноза: '||v_payout||' ₽','radio_prediction',v_rec.id,COALESCE(v_before,0),COALESCE(v_before,0)+v_payout);
    END IF;
    v_count:=v_count+1;
  END LOOP;
  RETURN v_count;
END; $$;
REVOKE ALL ON FUNCTION public.radio_resolve_predictions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.radio_resolve_predictions() TO authenticated;

-- Explicit admin rights for operational radio screens.
DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['radio_config','radio_queue','radio_schedule','radio_slots','radio_predictions','radio_ad_placements'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Administrators operate ' || v_table, v_table);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()))',
      'Administrators operate ' || v_table, v_table);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', v_table);
  END LOOP;
END $$;

COMMIT;
