-- ═══════════════════════════════════════════════════════════════
-- C1: Персонализация ленты — feed_personalization
-- Данные: track_likes, жанровые предпочтения
-- ═══════════════════════════════════════════════════════════════

INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('feed_personalization', '{"enabled": false, "weight": 1.5, "min_user_actions": 5, "diversity_factor": 0.2}'::jsonb, 'C1: Персонализация главной ленты по track_likes и жанрам')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- ─── Обновление get_smart_feed: персонализация + fix follows → user_follows ───

CREATE OR REPLACE FUNCTION public.get_smart_feed(
  p_user_id UUID DEFAULT NULL,
  p_stream TEXT DEFAULT 'main',
  p_genre_id UUID DEFAULT NULL,
  p_offset INTEGER DEFAULT 0,
  p_limit INTEGER DEFAULT 20
) RETURNS TABLE (
  id UUID,
  title TEXT,
  description TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration INTEGER,
  user_id UUID,
  genre_id UUID,
  is_public BOOLEAN,
  likes_count INTEGER,
  plays_count INTEGER,
  comments_count INTEGER,
  shares_count INTEGER,
  saves_count INTEGER,
  status TEXT,
  created_at TIMESTAMPTZ,
  profile_username TEXT,
  profile_avatar_url TEXT,
  profile_display_name TEXT,
  author_tier TEXT,
  author_tier_icon TEXT,
  author_tier_color TEXT,
  author_verified BOOLEAN,
  genre_name_ru TEXT,
  feed_score NUMERIC,
  feed_velocity NUMERIC,
  is_boosted BOOLEAN,
  boost_expires_at TIMESTAMPTZ,
  quality_score NUMERIC
) LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_config JSONB;
  v_decay JSONB;
  v_qg JSONB;
  v_following_ids UUID[];
  v_half_life NUMERIC;
  -- C1: персонализация
  v_personalization JSONB;
  v_pers_enabled BOOLEAN;
  v_pers_weight NUMERIC;
  v_pers_min_actions INT;
  v_user_genre_ids UUID[];
BEGIN
  -- Load config
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';

  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  -- C1: загрузка настроек персонализации
  SELECT value INTO v_personalization FROM forum_automod_settings WHERE key = 'feed_personalization' LIMIT 1;
  v_pers_enabled := COALESCE((v_personalization->>'enabled')::boolean, false);
  v_pers_weight := COALESCE((v_personalization->>'weight')::numeric, 1.5);
  v_pers_min_actions := COALESCE((v_personalization->>'min_user_actions')::int, 5);

  -- C1: жанры из лайков пользователя (если персонализация включена и достаточно действий)
  IF v_pers_enabled AND p_user_id IS NOT NULL AND p_stream = 'main' THEN
    IF (SELECT COUNT(*) FROM track_likes WHERE user_id = p_user_id) >= v_pers_min_actions THEN
      SELECT ARRAY_AGG(DISTINCT t.genre_id) INTO v_user_genre_ids
      FROM track_likes tl
      JOIN tracks t ON t.id = tl.track_id
      WHERE tl.user_id = p_user_id AND t.genre_id IS NOT NULL;
    END IF;
  END IF;

  -- Get following list for 'following' stream (fix: user_follows вместо follows)
  IF p_stream = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM public.user_follows
    WHERE follower_id = p_user_id;

    IF v_following_ids IS NULL OR array_length(v_following_ids, 1) IS NULL THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    t.id, t.title, t.description, t.audio_url, t.cover_url,
    t.duration, t.user_id, t.genre_id, t.is_public,
    t.likes_count, t.plays_count,
    (SELECT COUNT(*)::integer FROM public.track_comments tc WHERE tc.track_id = t.id) AS comments_count,
    COALESCE(t.shares_count, 0)::integer AS shares_count,
    (SELECT COUNT(*)::integer FROM public.playlist_tracks pt WHERE pt.track_id = t.id) AS saves_count,
    t.status, t.created_at,
    p.username AS profile_username,
    p.avatar_url AS profile_avatar_url,
    p.display_name AS profile_display_name,
    COALESCE(fus.tier, 'newcomer') AS author_tier,
    rt.icon AS author_tier_icon,
    rt.color AS author_tier_color,
    COALESCE(p.is_verified, false) AS author_verified,
    g.name_ru AS genre_name_ru,
    COALESCE(fs.final_score, 0) AS feed_score,
    COALESCE(fs.velocity_24h, 0) AS feed_velocity,
    (bt.id IS NOT NULL AND bt.expires_at > now()) AS is_boosted,
    bt.expires_at AS boost_expires_at,
    COALESCE(tqs.quality_score, 0) AS quality_score
  FROM public.tracks t
  LEFT JOIN public.profiles p ON p.user_id = t.user_id
  LEFT JOIN public.genres g ON g.id = t.genre_id
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
  LEFT JOIN public.reputation_tiers rt ON rt.key = COALESCE(fus.tier, 'newcomer')
  LEFT JOIN public.track_feed_scores fs ON fs.track_id = t.id
  LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
  LEFT JOIN LATERAL (
    SELECT bt2.id, bt2.ends_at AS expires_at
    FROM public.track_promotions bt2
    WHERE bt2.track_id = t.id AND bt2.status = 'active' AND bt2.ends_at > now()
    LIMIT 1
  ) bt ON true
  WHERE t.is_public = true
    AND t.status = 'completed'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE ub.user_id = t.user_id
        AND (ub.expires_at IS NULL OR ub.expires_at > now())
    )
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    AND (
      CASE p_stream
        WHEN 'following' THEN t.user_id = ANY(v_following_ids)
        WHEN 'trending' THEN
          COALESCE(t.plays_count, 0) >= COALESCE((v_qg->>'min_plays_for_trending')::int, 5)
          AND COALESCE(tqs.quality_score, 5) >= COALESCE((v_qg->>'min_score_for_trending')::numeric, 3.0)
        WHEN 'deep' THEN
          COALESCE(t.plays_count, 0) < 20
          AND t.created_at > now() - interval '14 days'
        ELSE true
      END
    )
    AND COALESCE(t.duration, 0) >= COALESCE((v_qg->>'min_duration_sec')::int, 30)
    AND COALESCE(fs.is_spam, false) = false
  ORDER BY
    CASE p_stream
      WHEN 'main' THEN
        COALESCE(fs.final_score, 0) *
        POWER(0.5, EXTRACT(EPOCH FROM (now() - t.created_at)) / 3600 / v_half_life)
        + CASE WHEN bt.id IS NOT NULL THEN 100 ELSE 0 END
        -- C1: буст для жанров из лайков пользователя
        + CASE
            WHEN v_user_genre_ids IS NOT NULL AND array_length(v_user_genre_ids, 1) > 0
                 AND t.genre_id = ANY(v_user_genre_ids)
            THEN 30 * v_pers_weight
            ELSE 0
          END
      WHEN 'trending' THEN COALESCE(fs.velocity_24h, 0)
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'following' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'deep' THEN random() * 100 + COALESCE(tqs.quality_score, 5) * 10
      ELSE EXTRACT(EPOCH FROM t.created_at)
    END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;
