-- ═══════════════════════════════════════════════════════════
-- Radio Engine v3 Migration
-- Adds: radio_listeners, radio_schedule
-- Updates: get_radio_smart_queue (boost integration),
--          get_radio_stats (extended), radio_heartbeat, get_radio_listeners
-- ═══════════════════════════════════════════════════════════

-- ─── 1. Table: radio_listeners (live presence) ────────────

CREATE TABLE IF NOT EXISTS public.radio_listeners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  last_heartbeat TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  genre_filter UUID REFERENCES public.genres(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT unique_radio_listener UNIQUE(user_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_radio_listeners_heartbeat
  ON public.radio_listeners(last_heartbeat DESC);

ALTER TABLE public.radio_listeners ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can see radio listeners" ON public.radio_listeners;
CREATE POLICY "Anyone can see radio listeners"
  ON public.radio_listeners FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can manage own listener entry" ON public.radio_listeners;
CREATE POLICY "Users can manage own listener entry"
  ON public.radio_listeners FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ─── 2. Table: radio_schedule (play history for engine) ───

CREATE TABLE IF NOT EXISTS public.radio_schedule (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'algorithm',
  priority INTEGER NOT NULL DEFAULT 0,
  scheduled_at TIMESTAMPTZ,
  played_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_radio_schedule_played
  ON public.radio_schedule(played_at DESC)
  WHERE played_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_radio_schedule_pending
  ON public.radio_schedule(priority DESC, scheduled_at ASC)
  WHERE played_at IS NULL;

ALTER TABLE public.radio_schedule ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view radio schedule" ON public.radio_schedule;
CREATE POLICY "Anyone can view radio schedule"
  ON public.radio_schedule FOR SELECT USING (true);

-- ─── 3. RPC: radio_heartbeat ──────────────────────────────

CREATE OR REPLACE FUNCTION public.radio_heartbeat(
  p_user_id UUID,
  p_session_id TEXT,
  p_genre_filter UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO public.radio_listeners (user_id, session_id, genre_filter, last_heartbeat)
  VALUES (p_user_id, p_session_id, p_genre_filter, NOW())
  ON CONFLICT ON CONSTRAINT unique_radio_listener
  DO UPDATE SET
    last_heartbeat = NOW(),
    genre_filter = COALESCE(EXCLUDED.genre_filter, radio_listeners.genre_filter);

  DELETE FROM public.radio_listeners
  WHERE last_heartbeat < NOW() - INTERVAL '3 minutes';

  SELECT COUNT(*) INTO v_count
  FROM public.radio_listeners
  WHERE last_heartbeat > NOW() - INTERVAL '2 minutes';

  RETURN jsonb_build_object(
    'ok', true,
    'listeners_count', v_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.radio_heartbeat TO authenticated;

-- ─── 4. RPC: get_radio_listeners ──────────────────────────

CREATE OR REPLACE FUNCTION public.get_radio_listeners(
  p_limit INTEGER DEFAULT 30
)
RETURNS TABLE(
  user_id UUID,
  username TEXT,
  avatar_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    rl.user_id,
    p.username,
    p.avatar_url
  FROM public.radio_listeners rl
  JOIN public.profiles p ON p.user_id = rl.user_id
  WHERE rl.last_heartbeat > NOW() - INTERVAL '2 minutes'
  ORDER BY rl.last_heartbeat DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_radio_listeners TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_radio_listeners TO anon;

-- ─── 5. Update: get_radio_smart_queue (boost integration) ─

DROP FUNCTION IF EXISTS public.get_radio_smart_queue(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE(
  track_id UUID,
  title TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration NUMERIC,
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
  is_boosted BOOLEAN,
  boost_type TEXT,
  promotion_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_config JSONB;
  v_w_quality NUMERIC;
  v_w_xp NUMERIC;
  v_w_stake NUMERIC;
  v_w_freshness NUMERIC;
  v_w_discovery NUMERIC;
  v_min_quality NUMERIC;
  v_min_duration INTEGER;
  v_discovery_days INTEGER;
  v_discovery_mult NUMERIC;
  v_max_author_pct NUMERIC;
BEGIN
  SELECT value INTO v_config FROM public.radio_config WHERE key = 'smart_stream';
  v_w_quality := COALESCE((v_config->>'W_quality')::NUMERIC, (v_config->>'w_quality')::NUMERIC, 0.35);
  v_w_xp := COALESCE((v_config->>'W_xp')::NUMERIC, (v_config->>'w_xp')::NUMERIC, 0.25);
  v_w_stake := COALESCE((v_config->>'W_stake')::NUMERIC, (v_config->>'w_stake')::NUMERIC, 0.20);
  v_w_freshness := COALESCE((v_config->>'W_freshness')::NUMERIC, (v_config->>'w_freshness')::NUMERIC, 0.15);
  v_w_discovery := COALESCE((v_config->>'W_discovery')::NUMERIC, (v_config->>'w_discovery')::NUMERIC, 0.05);
  v_min_quality := COALESCE((v_config->>'min_quality_score')::NUMERIC, 2.0);
  v_min_duration := COALESCE((v_config->>'min_duration_sec')::INTEGER, 30);
  v_discovery_days := COALESCE((v_config->>'discovery_boost_days')::INTEGER, 14);
  v_discovery_mult := COALESCE((v_config->>'discovery_boost_multiplier')::NUMERIC, 2.5);
  v_max_author_pct := COALESCE((v_config->>'max_author_share_percent')::NUMERIC, 15);

  RETURN QUERY
  WITH scored AS (
    SELECT
      t.id AS track_id,
      t.title,
      t.audio_url,
      t.cover_url,
      t.duration::NUMERIC,
      t.user_id AS author_id,
      p.username AS author_username,
      p.avatar_url AS author_avatar,
      COALESCE(fus.tier, p.subscription_tier, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, (COALESCE(p.xp_music, 0) + COALESCE(p.xp_forum, 0) + COALESCE(p.xp_social, 0)))::INTEGER AS author_xp,
      g.name_ru AS genre_name,
      LEAST(1.0, (COALESCE(t.likes_count, 0)::NUMERIC / GREATEST(1, COALESCE(t.plays_count, 1)))) AS quality_comp,
      LEAST(1.0, (COALESCE(p.xp_music, 0)::NUMERIC / 1000.0)) AS xp_comp,
      CASE
        WHEN t.created_at > NOW() - INTERVAL '1 day' THEN 1.0
        WHEN t.created_at > NOW() - INTERVAL '7 days' THEN 0.7
        WHEN t.created_at > NOW() - INTERVAL '30 days' THEN 0.4
        ELSE 0.2
      END AS freshness_comp,
      CASE
        WHEN t.created_at > NOW() - (v_discovery_days || ' days')::INTERVAL
             AND COALESCE(t.plays_count, 0) < 50
        THEN v_discovery_mult
        ELSE 1.0
      END AS discovery_mult,
      COALESCE(
        CASE tp.boost_type
          WHEN 'top' THEN 5.0
          WHEN 'premium' THEN 3.0
          WHEN 'standard' THEN 2.0
        END,
        1.0
      ) AS boost_mult,
      tp.boost_type AS promo_boost_type,
      tp.id AS promo_id,
      random() AS rng
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.track_promotions tp
      ON tp.track_id = t.id
      AND tp.is_active = true
      AND tp.expires_at > NOW()
    WHERE t.status = 'completed'
      AND t.is_public = true
      AND COALESCE(t.duration, 0) >= v_min_duration
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
  )
  SELECT
    s.track_id,
    s.title,
    s.audio_url,
    s.cover_url,
    s.duration,
    s.author_id,
    s.author_username,
    s.author_avatar,
    s.author_tier,
    s.author_xp,
    s.genre_name,
    ROUND((
      v_w_quality * s.quality_comp +
      v_w_xp * s.xp_comp +
      v_w_freshness * s.freshness_comp +
      v_w_discovery * LEAST(1.0, s.rng)
    ) * s.discovery_mult * s.boost_mult * (0.8 + 0.4 * s.rng), 4) AS chance_score,
    ROUND(s.quality_comp, 4) AS quality_component,
    ROUND(s.xp_comp, 4) AS xp_component,
    ROUND(s.freshness_comp, 4) AS freshness_component,
    ROUND(v_w_discovery * s.rng, 4) AS discovery_component,
    CASE WHEN s.promo_id IS NOT NULL THEN 'promotion' ELSE 'algorithm' END AS source,
    (s.promo_id IS NOT NULL) AS is_boosted,
    s.promo_boost_type AS boost_type,
    s.promo_id AS promotion_id
  FROM scored s
  ORDER BY chance_score DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue TO anon;

-- ─── 6. Update: get_radio_stats (extended) ────────────────

DROP FUNCTION IF EXISTS public.get_radio_stats();

CREATE OR REPLACE FUNCTION public.get_radio_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'listens_today', (SELECT COUNT(*) FROM public.radio_listens WHERE created_at > CURRENT_DATE),
    'listens_total', (SELECT COUNT(*) FROM public.radio_listens),
    'unique_listeners_today', (SELECT COUNT(DISTINCT user_id) FROM public.radio_listens WHERE created_at > CURRENT_DATE),
    'listeners_now', (SELECT COUNT(*) FROM public.radio_listeners WHERE last_heartbeat > NOW() - INTERVAL '2 minutes'),
    'active_slots', (SELECT COUNT(*) FROM public.radio_slots WHERE status IN ('open', 'bidding')),
    'pending_predictions', (SELECT COUNT(*) FROM public.radio_predictions WHERE status = 'pending'),
    'xp_awarded_today', (SELECT COALESCE(SUM(xp_earned), 0) FROM public.radio_listens WHERE created_at > CURRENT_DATE),
    'revenue_today', (
      SELECT COALESCE(SUM(winning_bid), 0)
      FROM public.radio_slots
      WHERE status = 'won' AND created_at > CURRENT_DATE
    ) + (
      SELECT COALESCE(SUM(price_paid), 0)
      FROM public.track_promotions
      WHERE created_at > CURRENT_DATE AND is_active = true
    ),
    'tracks_played_today', (SELECT COUNT(*) FROM public.radio_schedule WHERE played_at > CURRENT_DATE),
    'top_tracks_today', (
      SELECT COALESCE(jsonb_agg(row_to_json(top)), '[]'::jsonb)
      FROM (
        SELECT rl.track_id, t.title, COUNT(*) AS plays
        FROM public.radio_listens rl
        JOIN public.tracks t ON t.id = rl.track_id
        WHERE rl.created_at > CURRENT_DATE
        GROUP BY rl.track_id, t.title
        ORDER BY plays DESC
        LIMIT 5
      ) top
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_radio_stats TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_radio_stats TO anon;

-- ─── 7. Add to realtime (optional) ──────────────────────────

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.radio_schedule;
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.radio_listeners;
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;
