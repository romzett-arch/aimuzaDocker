-- ============================================================
-- RADIO MODULE — Tables, RPC functions, seed config
-- Реализация Интерактивного Радио (Smart Stream, L2E, Auction, Predictions)
-- ============================================================

-- ─── 1. Tables ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_config (
  key TEXT NOT NULL PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}',
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.radio_queue (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  source TEXT NOT NULL DEFAULT 'algorithm',
  position INTEGER NOT NULL DEFAULT 0,
  chance_score NUMERIC NOT NULL DEFAULT 0,
  quality_component NUMERIC NOT NULL DEFAULT 0,
  xp_component NUMERIC NOT NULL DEFAULT 0,
  freshness_component NUMERIC NOT NULL DEFAULT 0,
  discovery_component NUMERIC NOT NULL DEFAULT 0,
  is_played BOOLEAN NOT NULL DEFAULT false,
  played_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (track_id)
);

CREATE TABLE IF NOT EXISTS public.radio_listens (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  session_id TEXT,
  listen_duration_sec INTEGER NOT NULL DEFAULT 0,
  track_duration_sec INTEGER NOT NULL DEFAULT 0,
  listen_percent NUMERIC NOT NULL DEFAULT 0,
  xp_earned INTEGER NOT NULL DEFAULT 0,
  reaction TEXT CHECK (reaction IN ('like', 'dislike', 'skip', 'love', 'meh')),
  is_afk_verified BOOLEAN DEFAULT false,
  ip_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.radio_slots (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slot_number INTEGER NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'bidding', 'won', 'playing', 'completed', 'cancelled')),
  winner_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  winner_track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  winning_bid INTEGER DEFAULT 0,
  total_bids INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.radio_bids (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slot_id UUID NOT NULL REFERENCES public.radio_slots(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'outbid', 'won', 'refunded', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.radio_predictions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  bet_amount INTEGER NOT NULL,
  predicted_hit BOOLEAN NOT NULL,
  actual_result BOOLEAN,
  payout INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'won', 'lost', 'refunded')),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.radio_ad_placements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  advertiser_name TEXT,
  ad_type TEXT DEFAULT 'audio',
  audio_url TEXT,
  promo_text TEXT,
  price_paid INTEGER DEFAULT 0,
  impressions INTEGER DEFAULT 0,
  clicks INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  starts_at TIMESTAMPTZ DEFAULT now(),
  ends_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_radio_queue_is_played ON public.radio_queue(is_played);
CREATE INDEX IF NOT EXISTS idx_radio_listens_user_created ON public.radio_listens(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_radio_slots_status ON public.radio_slots(status);
CREATE INDEX IF NOT EXISTS idx_radio_bids_slot ON public.radio_bids(slot_id);
CREATE INDEX IF NOT EXISTS idx_radio_predictions_user_status ON public.radio_predictions(user_id, status);

-- RLS
ALTER TABLE public.radio_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_listens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_bids ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_predictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.radio_ad_placements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read radio_config" ON public.radio_config FOR SELECT USING (true);
CREATE POLICY "Anyone can read radio_queue" ON public.radio_queue FOR SELECT USING (true);
CREATE POLICY "Anyone can read radio_slots" ON public.radio_slots FOR SELECT USING (true);
CREATE POLICY "Anyone can read radio_bids" ON public.radio_bids FOR SELECT USING (true);
CREATE POLICY "Users can read own radio_listens" ON public.radio_listens FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can read own radio_predictions" ON public.radio_predictions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Anyone can read radio_ad_placements" ON public.radio_ad_placements FOR SELECT USING (is_active = true AND (ends_at IS NULL OR ends_at > now()));

-- Service role can insert/update (for radio worker)
CREATE POLICY "Service can manage radio_queue" ON public.radio_queue FOR ALL USING (true);
CREATE POLICY "Users can insert radio_listens" ON public.radio_listens FOR INSERT WITH CHECK (auth.uid() = user_id);

-- ─── 2. get_radio_smart_queue ─────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  track_id UUID,
  title TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration INTEGER,
  author_id UUID,
  author_username TEXT,
  author_avatar TEXT,
  author_tier TEXT,
  author_xp INTEGER,
  genre_name TEXT,
  chance_score NUMERIC,
  quality_component NUMERIC,
  xp_component NUMERIC,
  freshness_component NUMERIC,
  discovery_component NUMERIC,
  source TEXT,
  is_boosted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_w_quality NUMERIC := 0.35;
  v_w_xp NUMERIC := 0.25;
  v_w_stake NUMERIC := 0.20;
  v_w_freshness NUMERIC := 0.15;
  v_w_discovery NUMERIC := 0.05;
  v_min_quality NUMERIC := 2.0;
  v_min_duration INTEGER := 30;
  v_discovery_days INTEGER := 14;
  v_discovery_mult NUMERIC := 2.5;
BEGIN
  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS tid,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, 0)::INTEGER AS author_xp,
      g.name AS genre_name,
      -- Quality: likes + plays
      GREATEST(v_min_quality, 1 + COALESCE(t.likes_count, 0) * 0.5 + COALESCE(t.plays_count, 0) * 0.02) AS q,
      -- XP: normalized 0-1
      LEAST(1.0, COALESCE(fus.xp_total, 0)::NUMERIC / 500.0) AS xp,
      -- Stake: boost
      CASE WHEN tp.id IS NOT NULL THEN 1.5 ELSE 0.5 END AS stake,
      -- Freshness: decay
      1.0 / (1.0 + EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400.0 / 30.0) AS fresh,
      -- Discovery: new artist
      CASE WHEN p.created_at > now() - (v_discovery_days || ' days')::interval THEN v_discovery_mult ELSE 1.0 END AS disc,
      (tp.id IS NOT NULL) AS boosted
    FROM public.tracks t
    JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.track_promotions tp ON tp.track_id = t.id AND tp.status = 'active' AND (tp.expires_at > now() OR tp.ends_at > now())
    WHERE t.status = 'completed'
      AND t.is_public = true
      AND t.audio_url IS NOT NULL
      AND (t.duration IS NULL OR t.duration >= v_min_duration)
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
  )
  SELECT
    s.tid,
    s.title,
    s.audio_url,
    s.cover_url,
    s.duration::INTEGER,
    s.author_id,
    s.author_username,
    s.author_avatar,
    s.author_tier,
    s.author_xp,
    s.genre_name,
    (s.q * v_w_quality + s.xp * v_w_xp + s.stake * v_w_stake + s.fresh * v_w_freshness + s.disc * v_w_discovery)::NUMERIC AS chance_score,
    s.q::NUMERIC AS quality_component,
    s.xp::NUMERIC AS xp_component,
    s.fresh::NUMERIC AS freshness_component,
    s.disc::NUMERIC AS discovery_component,
    'algorithm'::TEXT AS source,
    s.boosted
  FROM scored s
  ORDER BY (s.q * v_w_quality + s.xp * v_w_xp + s.stake * v_w_stake + s.fresh * v_w_freshness + s.disc * v_w_discovery) DESC
  LIMIT p_limit;
END;
$$;

-- ─── 3. radio_award_listen_xp ─────────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID,
  p_track_id UUID,
  p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER,
  p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_hash TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listen_percent NUMERIC;
  v_xp_earned INTEGER := 0;
  v_xp_today INTEGER;
  v_daily_cap INTEGER := 50;
  v_min_percent NUMERIC := 60;
  v_xp_per_listen NUMERIC := 2;
  v_result JSONB;
BEGIN
  IF p_track_duration_sec <= 0 THEN
    p_track_duration_sec := 1;
  END IF;

  v_listen_percent := (p_listen_duration_sec::NUMERIC / p_track_duration_sec) * 100;

  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  IF v_listen_percent >= v_min_percent THEN
    v_xp_earned := LEAST(
      GREATEST(1, (v_xp_per_listen * (v_listen_percent / 100))::INTEGER),
      v_daily_cap - v_xp_today
    );
    IF v_xp_earned < 1 THEN
      v_xp_earned := 0;
    END IF;
  END IF;

  INSERT INTO public.radio_listens (
    user_id, track_id, session_id, listen_duration_sec, track_duration_sec,
    listen_percent, xp_earned, reaction, ip_hash
  ) VALUES (
    p_user_id, p_track_id, p_session_id, p_listen_duration_sec, p_track_duration_sec,
    v_listen_percent, v_xp_earned, p_reaction, p_ip_hash
  );

  IF v_xp_earned > 0 THEN
    PERFORM public.fn_add_xp(p_user_id, v_xp_earned, 'music', false);
  END IF;

  v_xp_today := v_xp_today + v_xp_earned;

  v_result := jsonb_build_object(
    'ok', true,
    'xp_earned', v_xp_earned,
    'listen_percent', v_listen_percent,
    'xp_today', v_xp_today,
    'daily_cap', v_daily_cap,
    'listens_today', (SELECT COUNT(*) FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap
  );

  RETURN v_result;
END;
$$;

-- ─── 4. radio_resolve_predictions ─────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_resolve_predictions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_rec RECORD;
  v_hit_threshold INTEGER := 5;
  v_actual_hit BOOLEAN;
BEGIN
  FOR v_rec IN
    SELECT rp.id, rp.track_id, rp.predicted_hit, rp.bet_amount, rp.user_id
    FROM public.radio_predictions rp
    WHERE rp.status = 'pending' AND rp.expires_at < now()
  LOOP
    SELECT (COALESCE(t.likes_count, 0) >= v_hit_threshold) INTO v_actual_hit
    FROM public.tracks t WHERE t.id = v_rec.track_id;

    UPDATE public.radio_predictions SET
      actual_result = v_actual_hit,
      status = CASE WHEN v_actual_hit = v_rec.predicted_hit THEN 'won' ELSE 'lost' END,
      payout = CASE WHEN v_actual_hit = v_rec.predicted_hit THEN (v_rec.bet_amount * 1.8)::INTEGER ELSE 0 END
    WHERE id = v_rec.id;

    IF v_actual_hit = v_rec.predicted_hit THEN
      UPDATE public.profiles SET balance = balance + (v_rec.bet_amount * 1.8)::INTEGER WHERE user_id = v_rec.user_id;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─── 5. radio_place_bid ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID,
  p_slot_id UUID,
  p_track_id UUID,
  p_amount INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot RECORD;
  v_min_bid INTEGER := 10;
  v_bid_step INTEGER := 5;
  v_highest INTEGER;
  v_balance INTEGER;
BEGIN
  SELECT * INTO v_slot FROM public.radio_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_found');
  END IF;
  IF v_slot.status NOT IN ('open', 'bidding') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  SELECT COALESCE(MAX(amount), 0) INTO v_highest FROM public.radio_bids WHERE slot_id = p_slot_id AND status = 'active';
  IF p_amount < v_min_bid OR p_amount < v_highest + v_bid_step THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_required', v_highest + v_bid_step);
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.radio_bids SET status = 'outbid' WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active';

  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount) VALUES (p_slot_id, p_user_id, p_track_id, p_amount);
  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;
  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1 WHERE id = p_slot_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$$;

-- ─── 6. radio_place_prediction ────────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_place_prediction(
  p_user_id UUID,
  p_track_id UUID,
  p_bet_amount INTEGER,
  p_predicted_hit BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_min INTEGER := 5;
  v_max INTEGER := 100;
  v_balance INTEGER;
  v_expires_hours INTEGER := 24;
BEGIN
  IF p_bet_amount < v_min OR p_bet_amount > v_max THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bet_amount', 'min', v_min, 'max', v_max);
  END IF;

  IF EXISTS (SELECT 1 FROM public.radio_predictions WHERE user_id = p_user_id AND track_id = p_track_id AND status = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_predicted');
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < p_bet_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  INSERT INTO public.radio_predictions (user_id, track_id, bet_amount, predicted_hit, expires_at)
  VALUES (p_user_id, p_track_id, p_bet_amount, p_predicted_hit, now() + (v_expires_hours || ' hours')::interval);

  UPDATE public.profiles SET balance = balance - p_bet_amount WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'bet_amount', p_bet_amount, 'predicted_hit', p_predicted_hit, 'expires_in_hours', v_expires_hours);
END;
$$;

-- ─── 7. radio_skip_ad ─────────────────────────────────────────

DROP FUNCTION IF EXISTS public.radio_skip_ad(UUID, UUID);

CREATE OR REPLACE FUNCTION public.radio_skip_ad(
  p_user_id UUID,
  p_ad_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_skip_price INTEGER := 5;
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_skip_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  UPDATE public.profiles SET balance = balance - v_skip_price WHERE user_id = p_user_id;
  UPDATE public.radio_ad_placements SET impressions = impressions + 1 WHERE id = p_ad_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ─── 8. get_radio_stats ───────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_radio_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listens_today BIGINT;
  v_listens_total BIGINT;
  v_unique_listeners BIGINT;
BEGIN
  SELECT COUNT(*) INTO v_listens_today FROM public.radio_listens WHERE created_at >= CURRENT_DATE;
  SELECT COUNT(*) INTO v_listens_total FROM public.radio_listens;
  SELECT COUNT(DISTINCT user_id) INTO v_unique_listeners FROM public.radio_listens;

  RETURN jsonb_build_object(
    'listens_today', v_listens_today,
    'listens_total', v_listens_total,
    'unique_listeners', v_unique_listeners,
    'active_slots', (SELECT COUNT(*) FROM public.radio_slots WHERE status IN ('open', 'bidding'))
  );
END;
$$;

-- ─── 9. Seed radio_config ─────────────────────────────────────

INSERT INTO public.radio_config (key, value) VALUES
  ('smart_stream', '{"w_quality": 0.35, "w_xp": 0.25, "w_stake": 0.20, "w_freshness": 0.15, "w_discovery": 0.05, "min_quality_score": 2.0, "min_duration_sec": 30, "discovery_boost_days": 14, "discovery_boost_multiplier": 2.5}'::jsonb),
  ('listen_to_earn', '{"xp_per_listen": 2, "min_listen_percent": 60, "daily_cap": 50, "afk_check_interval_sec": 120, "afk_max_failures": 3}'::jsonb),
  ('auction', '{"min_bid_rub": 10, "bid_step_rub": 5, "commission_percent": 20, "slot_duration_minutes": 30}'::jsonb),
  ('predictions', '{"min_bet": 5, "max_bet": 100, "hit_threshold_likes": 5, "payout_multiplier": 1.8}'::jsonb),
  ('advertising', '{"audio_ad_slot_every_n_tracks": 5, "skip_price_rub": 5}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- ─── 10. Grant execute (Supabase roles; skip if not present) ───

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.radio_award_listen_xp(UUID, UUID, INTEGER, INTEGER, TEXT, TEXT, TEXT) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.radio_place_bid(UUID, UUID, UUID, INTEGER) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.radio_place_prediction(UUID, UUID, INTEGER, BOOLEAN) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.radio_skip_ad(UUID, UUID) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.get_radio_stats() TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO anon;
    GRANT EXECUTE ON FUNCTION public.get_radio_stats() TO anon;
  END IF;
END $$;
