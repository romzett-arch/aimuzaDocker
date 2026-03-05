CREATE OR REPLACE FUNCTION public.get_radio_smart_queue(
  p_genre_id UUID DEFAULT NULL,
  p_mood TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE(
  track_id UUID, title TEXT, audio_url TEXT, cover_url TEXT,
  duration NUMERIC, author_id UUID, author_username TEXT, author_avatar TEXT,
  author_tier TEXT, author_xp INTEGER, genre_name TEXT,
  chance_score NUMERIC, quality_component NUMERIC, xp_component NUMERIC,
  freshness_component NUMERIC, discovery_component NUMERIC,
  source TEXT, is_boosted BOOLEAN, boost_type TEXT, promotion_id UUID
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
      COALESCE(fus.tier, p.subscription_type, 'newcomer') AS author_tier,
      COALESCE(fus.xp_total, p.xp, 0)::INTEGER AS author_xp,
      g.name_ru AS genre_name,
      LEAST(1.0, (COALESCE(t.likes_count, 0)::NUMERIC / GREATEST(1, COALESCE(t.plays_count, 1)))) AS quality_comp,
      LEAST(1.0, (COALESCE(p.xp, 0)::NUMERIC / 1000.0)) AS xp_comp,
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
      AND tp.status = 'active'
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
    ROUND(((
      v_w_quality * s.quality_comp +
      v_w_xp * s.xp_comp +
      v_w_freshness * s.freshness_comp +
      v_w_discovery * LEAST(1.0, s.rng)
    ) * s.discovery_mult * s.boost_mult * (0.8 + 0.4 * s.rng))::NUMERIC, 4) AS chance_score,
    ROUND(s.quality_comp::NUMERIC, 4) AS quality_component,
    ROUND(s.xp_comp::NUMERIC, 4) AS xp_component,
    ROUND(s.freshness_comp::NUMERIC, 4) AS freshness_component,
    ROUND((v_w_discovery * s.rng)::NUMERIC, 4) AS discovery_component,
    CASE WHEN s.promo_id IS NOT NULL THEN 'promotion' ELSE 'algorithm' END AS source,
    (s.promo_id IS NOT NULL) AS is_boosted,
    s.promo_boost_type AS boost_type,
    s.promo_id AS promotion_id
  FROM scored s
  ORDER BY chance_score DESC
  LIMIT p_limit;
END;
$$;
