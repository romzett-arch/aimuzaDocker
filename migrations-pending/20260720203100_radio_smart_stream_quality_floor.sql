BEGIN;

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
      GREATEST(v_min_quality,
        1 + COALESCE(t.likes_count, 0) * 0.5 + COALESCE(t.plays_count, 0) * 0.02
      )::NUMERIC AS q,
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
    FROM scored s
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

COMMIT;
