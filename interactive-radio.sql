-- ═══════════════════════════════════════════════════════════════
-- INTERACTIVE RADIO 2.0 — Smart Stream, Auction, L2E, Ads
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. Radio Config ────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}',
  label TEXT,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.radio_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS radio_config_read ON public.radio_config;
CREATE POLICY radio_config_read ON public.radio_config FOR SELECT USING (true);

INSERT INTO public.radio_config (key, value, label, description) VALUES
  ('smart_stream', '{
    "W_quality": 0.35,
    "W_xp": 0.25,
    "W_stake": 0.20,
    "W_freshness": 0.15,
    "W_discovery": 0.05,
    "discovery_boost_days": 14,
    "discovery_boost_multiplier": 2.5,
    "max_plays_per_track_per_hour": 3,
    "max_author_share_percent": 15,
    "min_quality_score": 2.0,
    "min_duration_sec": 30,
    "queue_size": 50,
    "recalc_interval_sec": 300
  }', 'Smart Stream', 'Веса алгоритма ротации: W1=quality, W2=xp, W3=stake, W4=freshness, W5=discovery. Discovery-лифт для новичков.'),

  ('auction', '{
    "enabled": true,
    "slot_duration_minutes": 60,
    "min_bid_rub": 10,
    "bid_step_rub": 5,
    "max_active_slots": 3,
    "cooldown_after_slot_hours": 4,
    "platform_commission_percent": 20,
    "author_share_percent": 80,
    "auto_extend_if_no_bids": false
  }', 'Аукцион слотов', 'Механика «Платных слотов» — аукцион за право быть следующим в эфире'),

  ('listen_to_earn', '{
    "enabled": true,
    "xp_per_full_listen": 2,
    "xp_per_reaction": 1,
    "xp_per_vote": 3,
    "xp_per_prediction_correct": 10,
    "xp_per_prediction_wrong": 1,
    "xp_daily_cap": 100,
    "xp_diminishing_after": 20,
    "xp_diminishing_rate": 0.5,
    "min_listen_percent": 60,
    "afk_check_interval_sec": 120,
    "afk_check_timeout_sec": 15,
    "afk_max_failures": 3,
    "afk_penalty_xp": -10,
    "bot_detection_same_ip_limit": 5,
    "bot_detection_speed_threshold_ms": 200
  }', 'Listen-to-Earn', 'Геймификация прослушивания: XP за слушание, реакции, голосования, прогнозы. Anti-AFK проверки.'),

  ('predictions', '{
    "enabled": true,
    "bet_min_rub": 5,
    "bet_max_rub": 100,
    "hit_threshold_likes": 10,
    "hit_window_hours": 24,
    "payout_multiplier": 1.8,
    "platform_commission_percent": 10,
    "burn_percent": 5,
    "refund_on_cancel": true
  }', 'Прогнозы', 'Система ставок: слушатели ставят на то, станет ли трек хитом. Комиссия + burn валюты.'),

  ('advertising', '{
    "enabled": false,
    "audio_ad_slot_every_n_tracks": 5,
    "audio_ad_max_duration_sec": 15,
    "sponsored_hour_enabled": false,
    "sponsored_hour_price_rub": 5000,
    "platform_ad_share_percent": 40,
    "author_ad_share_percent": 60,
    "skip_ad_price_rub": 5,
    "ad_free_for_tiers": ["producer", "maestro"]
  }', 'Реклама', 'AI-реклама: аудио-вставки, спонсорский час, распределение дохода между платформой и авторами'),

  ('server', '{
    "recommended_ram_gb": 4,
    "recommended_cpu_cores": 2,
    "recommended_ssd_gb": 50,
    "redis_recommended": true,
    "separate_container": true,
    "max_concurrent_listeners": 500,
    "websocket_heartbeat_sec": 30,
    "queue_worker_interval_ms": 5000,
    "cdn_for_audio": true,
    "audio_bitrate_kbps": 128,
    "buffer_ahead_tracks": 3
  }', 'Сервер', 'Рекомендуемые серверные параметры для модуля радио')
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  label = EXCLUDED.label,
  description = EXCLUDED.description,
  updated_at = now();

-- ─── 2. Radio Queue (server-managed) ────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID REFERENCES public.profiles(user_id),
  source TEXT NOT NULL DEFAULT 'algorithm',  -- 'algorithm','auction','boost','sponsored'
  position INTEGER NOT NULL DEFAULT 0,
  chance_score NUMERIC DEFAULT 0,
  quality_component NUMERIC DEFAULT 0,
  xp_component NUMERIC DEFAULT 0,
  stake_component NUMERIC DEFAULT 0,
  freshness_component NUMERIC DEFAULT 0,
  discovery_component NUMERIC DEFAULT 0,
  played_at TIMESTAMPTZ,
  is_played BOOLEAN DEFAULT false,
  genre_id UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_radio_queue_position ON public.radio_queue (position) WHERE NOT is_played;
CREATE INDEX IF NOT EXISTS idx_radio_queue_genre ON public.radio_queue (genre_id) WHERE NOT is_played;

ALTER TABLE public.radio_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_queue_read ON public.radio_queue;
CREATE POLICY radio_queue_read ON public.radio_queue FOR SELECT USING (true);

-- ─── 3. Radio Listens (L2E tracking) ───────────────────────

CREATE TABLE IF NOT EXISTS public.radio_listens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  session_id TEXT,
  listen_duration_sec INTEGER DEFAULT 0,
  track_duration_sec INTEGER DEFAULT 0,
  listen_percent NUMERIC DEFAULT 0,
  xp_earned INTEGER DEFAULT 0,
  reaction TEXT,          -- 'like','dislike','skip','love','meh'
  is_afk_verified BOOLEAN DEFAULT false,
  afk_response_ms INTEGER,
  ip_hash TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_radio_listens_user ON public.radio_listens (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_radio_listens_track ON public.radio_listens (track_id, created_at DESC);

ALTER TABLE public.radio_listens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_listens_own ON public.radio_listens;
CREATE POLICY radio_listens_own ON public.radio_listens FOR SELECT USING (true);

-- ─── 4. Radio Auction Slots ─────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slot_number INTEGER NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  status TEXT DEFAULT 'open',       -- 'open','bidding','won','playing','completed','cancelled'
  winner_user_id UUID,
  winner_track_id UUID REFERENCES public.tracks(id),
  winning_bid NUMERIC DEFAULT 0,
  total_bids INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_radio_slots_status ON public.radio_slots (status, starts_at);

ALTER TABLE public.radio_slots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_slots_read ON public.radio_slots;
CREATE POLICY radio_slots_read ON public.radio_slots FOR SELECT USING (true);

-- ─── 5. Radio Bids ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_bids (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slot_id UUID NOT NULL REFERENCES public.radio_slots(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  track_id UUID NOT NULL REFERENCES public.tracks(id),
  amount NUMERIC NOT NULL DEFAULT 0,
  status TEXT DEFAULT 'active',     -- 'active','outbid','won','refunded','cancelled'
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_radio_bids_slot ON public.radio_bids (slot_id, amount DESC);

ALTER TABLE public.radio_bids ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_bids_read ON public.radio_bids;
CREATE POLICY radio_bids_read ON public.radio_bids FOR SELECT USING (true);

-- ─── 6. Radio Predictions ───────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_predictions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  track_id UUID NOT NULL REFERENCES public.tracks(id),
  bet_amount NUMERIC NOT NULL DEFAULT 0,
  predicted_hit BOOLEAN NOT NULL DEFAULT true,  -- true=станет хитом, false=не станет
  actual_result BOOLEAN,
  payout NUMERIC DEFAULT 0,
  status TEXT DEFAULT 'pending',    -- 'pending','won','lost','refunded'
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_radio_predictions_user ON public.radio_predictions (user_id, status);
CREATE INDEX IF NOT EXISTS idx_radio_predictions_track ON public.radio_predictions (track_id, status);

ALTER TABLE public.radio_predictions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_predictions_own ON public.radio_predictions;
CREATE POLICY radio_predictions_own ON public.radio_predictions FOR SELECT USING (true);

-- ─── 7. Radio Ad Placements ─────────────────────────────────

CREATE TABLE IF NOT EXISTS public.radio_ad_placements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_name TEXT,
  ad_type TEXT DEFAULT 'audio_insert',  -- 'audio_insert','sponsored_hour','mention'
  audio_url TEXT,
  promo_text TEXT,
  price_paid NUMERIC DEFAULT 0,
  impressions INTEGER DEFAULT 0,
  clicks INTEGER DEFAULT 0,
  starts_at TIMESTAMPTZ DEFAULT now(),
  ends_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.radio_ad_placements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS radio_ads_read ON public.radio_ad_placements;
CREATE POLICY radio_ads_read ON public.radio_ad_placements FOR SELECT USING (true);

-- ─── 8. Smart Stream RPC ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
) RETURNS TABLE (
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
) LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_cfg JSONB;
  v_w_quality NUMERIC;
  v_w_xp NUMERIC;
  v_w_stake NUMERIC;
  v_w_freshness NUMERIC;
  v_w_discovery NUMERIC;
  v_discovery_days INTEGER;
  v_discovery_mult NUMERIC;
  v_min_quality NUMERIC;
  v_min_duration INTEGER;
  v_max_author_pct NUMERIC;
BEGIN
  -- Load config
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'smart_stream';

  v_w_quality     := COALESCE((v_cfg->>'W_quality')::numeric, 0.35);
  v_w_xp          := COALESCE((v_cfg->>'W_xp')::numeric, 0.25);
  v_w_stake       := COALESCE((v_cfg->>'W_stake')::numeric, 0.20);
  v_w_freshness   := COALESCE((v_cfg->>'W_freshness')::numeric, 0.15);
  v_w_discovery   := COALESCE((v_cfg->>'W_discovery')::numeric, 0.05);
  v_discovery_days := COALESCE((v_cfg->>'discovery_boost_days')::int, 14);
  v_discovery_mult := COALESCE((v_cfg->>'discovery_boost_multiplier')::numeric, 2.5);
  v_min_quality   := COALESCE((v_cfg->>'min_quality_score')::numeric, 2.0);
  v_min_duration  := COALESCE((v_cfg->>'min_duration_sec')::int, 30);
  v_max_author_pct := COALESCE((v_cfg->>'max_author_share_percent')::numeric, 15);

  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS track_id,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, 0)::integer AS author_xp,
      g.name_ru AS genre_name,
      -- Quality component (0-100): track quality + engagement
      LEAST(
        COALESCE(tqs.quality_score, 5) * 10 +
        LEAST(COALESCE(t.likes_count, 0), 50) * 0.5 +
        LEAST(COALESCE(t.plays_count, 0), 200) * 0.1,
        100
      )::numeric AS q_score,
      -- XP component (0-100): author reputation normalized
      LEAST(COALESCE(fus.xp_total, 0)::numeric / 50, 100)::numeric AS xp_score,
      -- Freshness component (0-100): newer = higher
      GREATEST(
        100 - EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400 * 3.33,
        0
      )::numeric AS fresh_score,
      -- Discovery component (0-100): boost for new authors
      (CASE
        WHEN COALESCE(fus.xp_total, 0) < 100
          AND t.created_at > now() - (v_discovery_days || ' days')::interval
        THEN 100 * v_discovery_mult
        ELSE 0
      END)::numeric AS disc_score,
      -- Stake component: from active promotions
      COALESCE((
        SELECT SUM(tp.amount)
        FROM public.track_promotions tp
        WHERE tp.track_id = t.id AND tp.status = 'active' AND tp.ends_at > now()
      ), 0) AS stake_score,
      -- Is boosted?
      EXISTS (
        SELECT 1 FROM public.track_promotions tp
        WHERE tp.track_id = t.id AND tp.status = 'active' AND tp.ends_at > now()
      ) AS is_boosted,
      t.genre_id
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
    WHERE t.is_public = true
      AND t.status = 'completed'
      AND t.audio_url IS NOT NULL
      AND COALESCE(t.duration, 0) >= v_min_duration
      -- Exclude blocked users
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks ub
        WHERE ub.user_id = t.user_id
          AND (ub.expires_at IS NULL OR ub.expires_at > now())
      )
      -- Genre filter
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
      -- Quality gate
      AND COALESCE(tqs.quality_score, 5) >= v_min_quality
  )
  SELECT
    s.track_id, s.title, s.audio_url, s.cover_url, s.duration,
    s.author_id, s.author_username, s.author_avatar, s.author_tier,
    s.author_xp, s.genre_name,
    -- Final chance score (weighted sum)
    (s.q_score * v_w_quality +
     s.xp_score * v_w_xp +
     LEAST(s.stake_score, 100) * v_w_stake +
     s.fresh_score * v_w_freshness +
     s.disc_score * v_w_discovery
    )::numeric + (random() * 10)::numeric AS chance_score, -- small randomness
    s.q_score AS quality_component,
    s.xp_score AS xp_component,
    s.fresh_score AS freshness_component,
    s.disc_score AS discovery_component,
    CASE WHEN s.is_boosted THEN 'boost' ELSE 'algorithm' END AS source,
    s.is_boosted
  FROM scored s
  ORDER BY
    -- Final score with randomization
    (s.q_score * v_w_quality +
     s.xp_score * v_w_xp +
     LEAST(s.stake_score, 100) * v_w_stake +
     s.fresh_score * v_w_freshness +
     s.disc_score * v_w_discovery
    ) + (random() * 10) DESC
  LIMIT p_limit;
END;
$$;

-- ─── 9. L2E: Award listening XP ─────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID,
  p_track_id UUID,
  p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER,
  p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_hash TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cfg JSONB;
  v_listen_pct NUMERIC;
  v_xp INTEGER := 0;
  v_xp_today INTEGER;
  v_daily_cap INTEGER;
  v_diminish_after INTEGER;
  v_diminish_rate NUMERIC;
  v_min_pct NUMERIC;
  v_listens_today INTEGER;
  v_result JSONB;
  v_last_listen TIMESTAMPTZ;
  v_same_track_count INTEGER;
  v_ip_session_count INTEGER;
BEGIN
  -- Check if user is blocked
  IF public.is_user_blocked(p_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_blocked');
  END IF;

  -- *** ANTI-ABUSE: Cooldown — min 10 seconds between award calls ***
  SELECT MAX(created_at) INTO v_last_listen
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at > now() - INTERVAL '10 seconds';

  IF v_last_listen IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cooldown', 'reason', 'min 10 sec between listens');
  END IF;

  -- *** ANTI-ABUSE: Same track spam — max 3 rewards per track per day ***
  SELECT COUNT(*) INTO v_same_track_count
  FROM public.radio_listens
  WHERE user_id = p_user_id AND track_id = p_track_id
    AND created_at >= CURRENT_DATE AND xp_earned > 0;

  IF v_same_track_count >= 3 THEN
    -- Still record but no XP
    INSERT INTO public.radio_listens (
      user_id, track_id, listen_duration_sec, track_duration_sec,
      listen_percent, xp_earned, reaction, session_id, ip_hash
    ) VALUES (
      p_user_id, p_track_id, LEAST(p_listen_duration_sec, p_track_duration_sec),
      p_track_duration_sec, 0, 0, p_reaction, p_session_id, p_ip_hash
    );
    RETURN jsonb_build_object('ok', true, 'xp_earned', 0, 'reason', 'same_track_limit');
  END IF;

  -- *** ANTI-ABUSE: IP-based bot detection — max 5 sessions per IP ***
  IF p_ip_hash IS NOT NULL THEN
    SELECT COUNT(DISTINCT session_id) INTO v_ip_session_count
    FROM public.radio_listens
    WHERE ip_hash = p_ip_hash AND created_at >= CURRENT_DATE
      AND session_id != COALESCE(p_session_id, '');

    IF v_ip_session_count >= 5 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ip_limit', 'reason', 'too many sessions from same IP');
    END IF;
  END IF;

  -- *** ANTI-ABUSE: Clamp listen_duration to physical reality ***
  -- Cannot listen longer than track duration + 10% tolerance
  IF p_track_duration_sec > 0 THEN
    p_listen_duration_sec := LEAST(p_listen_duration_sec,
      CEIL(p_track_duration_sec * 1.1)::integer);
  END IF;

  -- Load config
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'listen_to_earn';

  v_daily_cap := COALESCE((v_cfg->>'xp_daily_cap')::int, 100);
  v_diminish_after := COALESCE((v_cfg->>'xp_diminishing_after')::int, 20);
  v_diminish_rate := COALESCE((v_cfg->>'xp_diminishing_rate')::numeric, 0.5);
  v_min_pct := COALESCE((v_cfg->>'min_listen_percent')::numeric, 60);

  -- Calculate listen percentage (clamped to 0-100)
  v_listen_pct := CASE
    WHEN p_track_duration_sec > 0 THEN LEAST(p_listen_duration_sec::numeric / p_track_duration_sec * 100, 100)
    ELSE 0
  END;

  -- Check daily XP cap
  SELECT COALESCE(SUM(xp_earned), 0) INTO v_xp_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;

  IF v_xp_today >= v_daily_cap THEN
    -- Still record the listen, but no XP
    INSERT INTO public.radio_listens (
      user_id, track_id, listen_duration_sec, track_duration_sec,
      listen_percent, xp_earned, reaction, session_id, ip_hash
    ) VALUES (
      p_user_id, p_track_id, p_listen_duration_sec, p_track_duration_sec,
      v_listen_pct, 0, p_reaction, p_session_id, p_ip_hash
    );
    RETURN jsonb_build_object('ok', true, 'xp_earned', 0, 'reason', 'daily_cap_reached',
      'xp_today', v_xp_today, 'daily_cap', v_daily_cap);
  END IF;

  -- Count today's listens for diminishing returns
  SELECT COUNT(*) INTO v_listens_today
  FROM public.radio_listens
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE AND xp_earned > 0;

  -- Base XP for full listen
  IF v_listen_pct >= v_min_pct THEN
    v_xp := COALESCE((v_cfg->>'xp_per_full_listen')::int, 2);
  END IF;

  -- Bonus XP for reaction
  IF p_reaction IS NOT NULL AND p_reaction != 'skip' THEN
    v_xp := v_xp + COALESCE((v_cfg->>'xp_per_reaction')::int, 1);
  END IF;

  -- Apply diminishing returns
  IF v_listens_today >= v_diminish_after THEN
    v_xp := GREATEST(FLOOR(v_xp * POWER(v_diminish_rate,
      (v_listens_today - v_diminish_after + 1)::numeric / 10)), 1);
  END IF;

  -- Cap to daily limit
  v_xp := LEAST(v_xp, v_daily_cap - v_xp_today);

  -- Record listen
  INSERT INTO public.radio_listens (
    user_id, track_id, listen_duration_sec, track_duration_sec,
    listen_percent, xp_earned, reaction, session_id, ip_hash
  ) VALUES (
    p_user_id, p_track_id, p_listen_duration_sec, p_track_duration_sec,
    v_listen_pct, v_xp, p_reaction, p_session_id, p_ip_hash
  );

  -- Award XP via reputation system (correct parameter order)
  IF v_xp > 0 THEN
    PERFORM public.safe_award_xp(p_user_id, 'radio_listen', 'track', p_track_id, jsonb_build_object('listen_pct', v_listen_pct));
  END IF;

  -- Update track plays_count
  UPDATE public.tracks SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id AND v_listen_pct >= v_min_pct;

  RETURN jsonb_build_object(
    'ok', true,
    'xp_earned', v_xp,
    'listen_percent', ROUND(v_listen_pct, 1),
    'xp_today', v_xp_today + v_xp,
    'daily_cap', v_daily_cap,
    'listens_today', v_listens_today + 1,
    'diminishing', v_listens_today >= v_diminish_after
  );
END;
$$;

-- ─── 10. Auction: Place Bid ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_place_bid(
  p_user_id UUID,
  p_slot_id UUID,
  p_track_id UUID,
  p_amount NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cfg JSONB;
  v_slot RECORD;
  v_min_bid NUMERIC;
  v_bid_step NUMERIC;
  v_current_max NUMERIC;
  v_user_balance NUMERIC;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'auction';

  v_min_bid := COALESCE((v_cfg->>'min_bid_rub')::numeric, 10);
  v_bid_step := COALESCE((v_cfg->>'bid_step_rub')::numeric, 5);

  -- *** CRITICAL: Lock slot row to serialize concurrent bids ***
  SELECT * INTO v_slot FROM public.radio_slots
  WHERE id = p_slot_id AND status IN ('open', 'bidding')
  FOR UPDATE;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_not_available');
  END IF;

  -- Lock user balance row to prevent double-spend
  SELECT COALESCE(balance, 0) INTO v_user_balance FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;
  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Check minimum bid (serialized — safe from TOCTOU)
  SELECT COALESCE(MAX(amount), 0) INTO v_current_max FROM public.radio_bids
  WHERE slot_id = p_slot_id AND status = 'active';

  IF p_amount < GREATEST(v_min_bid, v_current_max + v_bid_step) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low',
      'min_required', GREATEST(v_min_bid, v_current_max + v_bid_step));
  END IF;

  -- Refund previous bids from this user on this slot
  -- (return money BEFORE deducting new bid)
  UPDATE public.profiles SET balance = balance + rb.amount
  FROM (SELECT amount FROM public.radio_bids
        WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active') rb
  WHERE user_id = p_user_id;

  UPDATE public.radio_bids SET status = 'refunded'
  WHERE slot_id = p_slot_id AND user_id = p_user_id AND status = 'active';

  -- Refund ALL other active bidders on this slot (outbid)
  UPDATE public.profiles p SET balance = p.balance + rb.amount
  FROM public.radio_bids rb
  WHERE rb.slot_id = p_slot_id AND rb.status = 'active'
    AND rb.user_id != p_user_id AND rb.user_id = p.user_id;

  UPDATE public.radio_bids SET status = 'outbid'
  WHERE slot_id = p_slot_id AND status = 'active' AND user_id != p_user_id;

  -- Hold funds: deduct new bid from balance
  UPDATE public.profiles SET balance = balance - p_amount WHERE user_id = p_user_id;

  -- Place new bid (only active bid on this slot after cleanup above)
  INSERT INTO public.radio_bids (slot_id, user_id, track_id, amount, status)
  VALUES (p_slot_id, p_user_id, p_track_id, p_amount, 'active');

  -- Update slot status
  UPDATE public.radio_slots SET status = 'bidding', total_bids = total_bids + 1
  WHERE id = p_slot_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'slot_id', p_slot_id);
END;
$$;

-- ─── 11. Predictions: Place Bet ──────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_place_prediction(
  p_user_id UUID,
  p_track_id UUID,
  p_bet_amount NUMERIC,
  p_predicted_hit BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cfg JSONB;
  v_min_bet NUMERIC;
  v_max_bet NUMERIC;
  v_window_hours INTEGER;
  v_user_balance NUMERIC;
  v_track_author UUID;
  v_account_age_days INTEGER;
  v_daily_predictions INTEGER;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'predictions';

  v_min_bet := COALESCE((v_cfg->>'bet_min_rub')::numeric, 5);
  v_max_bet := COALESCE((v_cfg->>'bet_max_rub')::numeric, 100);
  v_window_hours := COALESCE((v_cfg->>'hit_window_hours')::int, 24);

  IF p_bet_amount < v_min_bet OR p_bet_amount > v_max_bet THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bet_amount',
      'min', v_min_bet, 'max', v_max_bet);
  END IF;

  -- *** ANTI-ABUSE: Author cannot bet on own track ***
  SELECT user_id INTO v_track_author FROM public.tracks WHERE id = p_track_id;
  IF v_track_author = p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_prediction_forbidden',
      'reason', 'Cannot predict on your own track');
  END IF;

  -- *** ANTI-ABUSE: Min account age 7 days ***
  SELECT EXTRACT(DAY FROM (now() - created_at))::integer INTO v_account_age_days
  FROM public.profiles WHERE user_id = p_user_id;
  IF COALESCE(v_account_age_days, 0) < 7 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_too_new',
      'reason', 'Account must be at least 7 days old');
  END IF;

  -- *** ANTI-ABUSE: Max 10 predictions per day per user ***
  SELECT COUNT(*) INTO v_daily_predictions
  FROM public.radio_predictions
  WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_daily_predictions >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_prediction_limit');
  END IF;

  -- Check balance (with row lock to prevent double-spend)
  SELECT COALESCE(balance, 0) INTO v_user_balance FROM public.profiles
  WHERE user_id = p_user_id FOR UPDATE;
  IF v_user_balance < p_bet_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance');
  END IF;

  -- Check no existing prediction on this track
  IF EXISTS (SELECT 1 FROM public.radio_predictions
    WHERE user_id = p_user_id AND track_id = p_track_id AND status = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_predicted');
  END IF;

  -- Deduct bet (safe: row already locked above)
  UPDATE public.profiles SET balance = balance - p_bet_amount WHERE user_id = p_user_id;

  -- Create prediction
  INSERT INTO public.radio_predictions (
    user_id, track_id, bet_amount, predicted_hit, expires_at
  ) VALUES (
    p_user_id, p_track_id, p_bet_amount, p_predicted_hit,
    now() + (v_window_hours || ' hours')::interval
  );

  RETURN jsonb_build_object('ok', true, 'bet_amount', p_bet_amount,
    'predicted_hit', p_predicted_hit, 'expires_in_hours', v_window_hours);
END;
$$;

-- ─── 12. Predictions: Resolve ────────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_resolve_predictions()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cfg JSONB;
  v_threshold INTEGER;
  v_multiplier NUMERIC;
  v_commission NUMERIC;
  v_burn NUMERIC;
  v_count INTEGER := 0;
  rec RECORD;
BEGIN
  SELECT value INTO v_cfg FROM radio_config WHERE key = 'predictions';

  v_threshold := COALESCE((v_cfg->>'hit_threshold_likes')::int, 10);
  v_multiplier := COALESCE((v_cfg->>'payout_multiplier')::numeric, 1.8);
  v_commission := COALESCE((v_cfg->>'platform_commission_percent')::numeric, 10) / 100;
  v_burn := COALESCE((v_cfg->>'burn_percent')::numeric, 5) / 100;

  FOR rec IN
    SELECT rp.*, t.likes_count
    FROM public.radio_predictions rp
    JOIN public.tracks t ON t.id = rp.track_id
    WHERE rp.status = 'pending' AND rp.expires_at <= now()
  LOOP
    -- Determine if track is a hit
    IF rec.likes_count >= v_threshold THEN
      -- Track is a hit
      IF rec.predicted_hit THEN
        -- Correct prediction: payout
        UPDATE public.radio_predictions SET
          status = 'won', actual_result = true,
          payout = rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE id = rec.id;
        -- Credit winnings
        UPDATE public.profiles SET balance = balance + rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE user_id = rec.user_id;
        -- Award XP (correct parameter order: user, event, source_type, source_id, metadata)
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_correct', 'track', rec.track_id, '{}'::jsonb);
      ELSE
        -- Wrong prediction: lose bet
        UPDATE public.radio_predictions SET status = 'lost', actual_result = true WHERE id = rec.id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_wrong', 'track', rec.track_id, '{}'::jsonb);
      END IF;
    ELSE
      -- Track is not a hit
      IF NOT rec.predicted_hit THEN
        -- Correct: payout
        UPDATE public.radio_predictions SET
          status = 'won', actual_result = false,
          payout = rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE id = rec.id;
        UPDATE public.profiles SET balance = balance + rec.bet_amount * v_multiplier * (1 - v_commission - v_burn)
        WHERE user_id = rec.user_id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_correct', 'track', rec.track_id, '{}'::jsonb);
      ELSE
        -- Wrong: lose bet
        UPDATE public.radio_predictions SET status = 'lost', actual_result = false WHERE id = rec.id;
        PERFORM public.safe_award_xp(rec.user_id, 'prediction_wrong', 'track', rec.track_id, '{}'::jsonb);
      END IF;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─── 13. Radio Stats ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_radio_stats()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_listens_today', (SELECT COUNT(*) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'unique_listeners_today', (SELECT COUNT(DISTINCT user_id) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'xp_awarded_today', (SELECT COALESCE(SUM(xp_earned), 0) FROM radio_listens WHERE created_at >= CURRENT_DATE),
    'active_predictions', (SELECT COUNT(*) FROM radio_predictions WHERE status = 'pending'),
    'predictions_pool', (SELECT COALESCE(SUM(bet_amount), 0) FROM radio_predictions WHERE status = 'pending'),
    'active_slots', (SELECT COUNT(*) FROM radio_slots WHERE status IN ('open', 'bidding')),
    'total_auction_revenue', (SELECT COALESCE(SUM(winning_bid), 0) FROM radio_slots WHERE status = 'completed'),
    'tracks_in_queue', (SELECT COUNT(*) FROM radio_queue WHERE NOT is_played),
    'top_track_today', (
      SELECT jsonb_build_object('track_id', track_id, 'listens', COUNT(*))
      FROM radio_listens WHERE created_at >= CURRENT_DATE
      GROUP BY track_id ORDER BY COUNT(*) DESC LIMIT 1
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- ─── 14. Skip Ad (atomic balance deduction) ─────────────────

CREATE OR REPLACE FUNCTION public.radio_skip_ad(
  p_user_id UUID,
  p_ad_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_price NUMERIC;
  v_balance NUMERIC;
BEGIN
  -- Get skip price from config
  SELECT COALESCE((value->>'skip_ad_price_rub')::numeric, 5) INTO v_price
  FROM public.radio_config WHERE key = 'advertising';

  -- Lock user balance row (prevents double-spend, race condition)
  SELECT COALESCE(balance, 0) INTO v_balance
  FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;

  IF v_balance < v_price THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
      'balance', v_balance, 'price', v_price);
  END IF;

  -- Atomic deduction
  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = p_user_id;

  -- Track the skip if ad_id provided
  IF p_ad_id IS NOT NULL THEN
    UPDATE public.radio_ad_placements
    SET clicks = COALESCE(clicks, 0) + 1
    WHERE id = p_ad_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'charged', v_price, 'new_balance', v_balance - v_price);
END;
$$;
