-- ═══════════════════════════════════════════════════════════════
-- C2: Умное радио — smart_radio
-- Данные: radio_listens (like/dislike/skip/love/meh)
-- Адаптация очереди под предпочтения слушателя
-- ═══════════════════════════════════════════════════════════════

INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('smart_radio', '{"enabled": false, "adaptation_speed": 0.5, "genre_lock": false, "mood_detection": false}'::jsonb, 'C2: Адаптация радио-очереди по radio_listens.reaction (like/dislike/skip)')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- ─── Обновление get_radio_smart_queue: учёт radio_listens.reaction ───

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
  -- C2: smart_radio
  v_smart_radio JSONB;
  v_sr_enabled BOOLEAN;
  v_sr_adaptation NUMERIC;
  v_user_liked_genres UUID[];
  v_user_disliked_genres UUID[];
  v_user_disliked_tracks UUID[];
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

  -- C2: загрузка smart_radio и предпочтений пользователя
  SELECT value INTO v_smart_radio FROM forum_automod_settings WHERE key = 'smart_radio' LIMIT 1;
  v_sr_enabled := COALESCE((v_smart_radio->>'enabled')::boolean, false);
  v_sr_adaptation := COALESCE((v_smart_radio->>'adaptation_speed')::numeric, 0.5);

  IF v_sr_enabled AND p_user_id IS NOT NULL THEN
    -- Жанры из лайков (like, love)
    SELECT ARRAY_AGG(DISTINCT t.genre_id) INTO v_user_liked_genres
    FROM radio_listens rl
    JOIN tracks t ON t.id = rl.track_id
    WHERE rl.user_id = p_user_id
      AND rl.reaction IN ('like', 'love')
      AND t.genre_id IS NOT NULL;

    -- Жанры из дизлайков (dislike, skip, meh)
    SELECT ARRAY_AGG(DISTINCT t.genre_id) INTO v_user_disliked_genres
    FROM radio_listens rl
    JOIN tracks t ON t.id = rl.track_id
    WHERE rl.user_id = p_user_id
      AND rl.reaction IN ('dislike', 'skip', 'meh')
      AND t.genre_id IS NOT NULL;

    -- Треки, которые пользователь явно дизлайкнул (исключаем)
    SELECT ARRAY_AGG(DISTINCT track_id) INTO v_user_disliked_tracks
    FROM radio_listens
    WHERE user_id = p_user_id AND reaction = 'dislike';
  END IF;

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
      LEAST(
        COALESCE(tqs.quality_score, 5) * 10 +
        LEAST(COALESCE(t.likes_count, 0), 50) * 0.5 +
        LEAST(COALESCE(t.plays_count, 0), 200) * 0.1,
        100
      )::numeric AS q_score,
      LEAST(COALESCE(fus.xp_total, 0)::numeric / 50, 100)::numeric AS xp_score,
      GREATEST(
        100 - EXTRACT(EPOCH FROM (now() - t.created_at)) / 86400 * 3.33,
        0
      )::numeric AS fresh_score,
      (CASE
        WHEN COALESCE(fus.xp_total, 0) < 100
          AND t.created_at > now() - (v_discovery_days || ' days')::interval
        THEN 100 * v_discovery_mult
        ELSE 0
      END)::numeric AS disc_score,
      COALESCE((
        SELECT SUM(tp.amount)
        FROM public.track_promotions tp
        WHERE tp.track_id = t.id AND tp.status = 'active' AND tp.ends_at > now()
      ), 0) AS stake_score,
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
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks ub
        WHERE ub.user_id = t.user_id
          AND (ub.expires_at IS NULL OR ub.expires_at > now())
      )
      AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
      AND COALESCE(tqs.quality_score, 5) >= v_min_quality
      -- C2: исключаем треки, которые пользователь явно дизлайкнул
      AND (v_user_disliked_tracks IS NULL OR t.id != ALL(v_user_disliked_tracks))
  )
  SELECT
    s.track_id, s.title, s.audio_url, s.cover_url, s.duration,
    s.author_id, s.author_username, s.author_avatar, s.author_tier,
    s.author_xp, s.genre_name,
    -- Final chance score + C2 personalization
    (
      (s.q_score * v_w_quality +
       s.xp_score * v_w_xp +
       LEAST(s.stake_score, 100) * v_w_stake +
       s.fresh_score * v_w_freshness +
       s.disc_score * v_w_discovery
      )
      + (random() * 10)
      -- C2: буст/штраф по жанрам из radio_listens
      + CASE
          WHEN v_sr_enabled AND p_user_id IS NOT NULL AND v_user_liked_genres IS NOT NULL
               AND s.genre_id = ANY(v_user_liked_genres)
          THEN 25 * v_sr_adaptation
          WHEN v_sr_enabled AND p_user_id IS NOT NULL AND v_user_disliked_genres IS NOT NULL
               AND s.genre_id = ANY(v_user_disliked_genres)
          THEN -35 * v_sr_adaptation
          ELSE 0
        END
    )::numeric AS chance_score,
    s.q_score AS quality_component,
    s.xp_score AS xp_component,
    s.fresh_score AS freshness_component,
    s.disc_score AS discovery_component,
    CASE WHEN s.is_boosted THEN 'boost' ELSE 'algorithm' END AS source,
    s.is_boosted
  FROM scored s
  ORDER BY
    (
      (s.q_score * v_w_quality +
       s.xp_score * v_w_xp +
       LEAST(s.stake_score, 100) * v_w_stake +
       s.fresh_score * v_w_freshness +
       s.disc_score * v_w_discovery
      )
      + (random() * 10)
      + CASE
          WHEN v_sr_enabled AND p_user_id IS NOT NULL AND v_user_liked_genres IS NOT NULL
               AND s.genre_id = ANY(v_user_liked_genres)
          THEN 25 * v_sr_adaptation
          WHEN v_sr_enabled AND p_user_id IS NOT NULL AND v_user_disliked_genres IS NOT NULL
               AND s.genre_id = ANY(v_user_disliked_genres)
          THEN -35 * v_sr_adaptation
          ELSE 0
        END
    ) DESC
  LIMIT p_limit;
END;
$$;
