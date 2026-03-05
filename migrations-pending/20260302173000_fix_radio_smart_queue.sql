-- Исправление: DROP + CREATE для get_radio_smart_queue (изменились OUT параметры)
DROP FUNCTION IF EXISTS public.get_radio_smart_queue(UUID, UUID, INTEGER);

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
      GREATEST(v_min_quality, 1 + COALESCE(t.likes_count, 0) * 0.5 + COALESCE(t.plays_count, 0) * 0.02) AS q,
      LEAST(1.0, COALESCE(fus.xp_total, 0)::NUMERIC / 500.0) AS xp,
      -- Stake: boost + subscription radio_weight_multiplier
      CASE WHEN tp.id IS NOT NULL THEN 1.5 ELSE 0.5 END
        * COALESCE(sp.radio_weight_multiplier, 1.0) AS stake,
      1.0 / (1.0 + EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400.0 / 30.0) AS fresh,
      CASE WHEN p.created_at > now() - (v_discovery_days || ' days')::interval THEN v_discovery_mult ELSE 1.0 END AS disc,
      (tp.id IS NOT NULL) AS boosted
    FROM public.tracks t
    JOIN public.profiles p ON p.user_id = t.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
    LEFT JOIN public.genres g ON g.id = t.genre_id
    LEFT JOIN public.track_promotions tp ON tp.track_id = t.id AND tp.status = 'active' AND (tp.expires_at > now() OR tp.ends_at > now())
    LEFT JOIN public.user_subscriptions us ON us.user_id = t.user_id AND us.status = 'active' AND us.current_period_end > now()
    LEFT JOIN public.subscription_plans sp ON sp.id = us.plan_id
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

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT EXECUTE ON FUNCTION public.get_radio_smart_queue(UUID, UUID, INTEGER) TO anon;
  END IF;
END $$;
