-- ═══════════════════════════════════════════════════════════════
-- SMART FEED 2.0 — Intelligent content ranking & distribution
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. Feed config: real-time algorithm tuning ─────────────

CREATE TABLE IF NOT EXISTS public.feed_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}',
  label TEXT,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.feed_config ENABLE ROW LEVEL SECURITY;

-- Insert default algorithm coefficients
INSERT INTO public.feed_config (key, value, label, description) VALUES
  ('ranking_weights', '{
    "likes": 5,
    "plays": 1,
    "comments": 8,
    "shares": 12,
    "saves": 10,
    "completion_rate": 3,
    "unique_listeners": 4
  }', 'Веса взаимодействий', 'Сколько баллов даёт каждое действие для engagement score'),

  ('time_decay', '{
    "half_life_hours": 48,
    "min_score_multiplier": 0.05,
    "boost_first_hours": 6,
    "boost_multiplier": 2.0
  }', 'Временной распад', 'Как быстро контент теряет позиции: half_life = время до потери 50% score'),

  ('tier_weights', '{
    "newcomer": 1.0,
    "beat_maker": 1.5,
    "sound_designer": 2.0,
    "producer": 3.0,
    "maestro": 5.0
  }', 'Веса тиров', 'Множитель взаимодействий от юзеров разных тиров (лайк от Маэстро ×5)'),

  ('quality_gate', '{
    "min_score_for_trending": 3.0,
    "min_score_for_recommendations": 2.0,
    "spam_threshold": 1.0,
    "min_duration_sec": 30,
    "min_plays_for_trending": 5
  }', 'Quality Gate', 'Минимальные пороги для попадания в разные ленты'),

  ('antifraud', '{
    "max_likes_per_user_per_track": 1,
    "min_play_duration_percent": 30,
    "self_play_excluded": true,
    "same_ip_diminishing": true,
    "new_account_weight_reduction": 0.3,
    "new_account_days_threshold": 3
  }', 'Антифрод', 'Параметры защиты от накруток'),

  ('feed_streams', '{
    "main": { "enabled": true, "label": "Главная", "algorithm": "smart" },
    "trending": { "enabled": true, "label": "В тренде", "algorithm": "velocity" },
    "fresh": { "enabled": true, "label": "Свежее", "algorithm": "chronological" },
    "following": { "enabled": true, "label": "Подписки", "algorithm": "following" },
    "deep": { "enabled": true, "label": "Глубинка", "algorithm": "underrated" }
  }', 'Потоки ленты', 'Доступные табы ленты и их алгоритмы')
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  label = EXCLUDED.label,
  description = EXCLUDED.description,
  updated_at = now();

-- ─── 2. Track engagement cache (materialized scores) ────────

CREATE TABLE IF NOT EXISTS public.track_feed_scores (
  track_id UUID PRIMARY KEY REFERENCES public.tracks(id) ON DELETE CASCADE,
  raw_engagement NUMERIC DEFAULT 0,
  weighted_engagement NUMERIC DEFAULT 0,
  velocity_1h NUMERIC DEFAULT 0,
  velocity_24h NUMERIC DEFAULT 0,
  time_decay_factor NUMERIC DEFAULT 1.0,
  final_score NUMERIC DEFAULT 0,
  stream_eligible TEXT[] DEFAULT '{}',
  is_spam BOOLEAN DEFAULT false,
  calculated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feed_scores_final
  ON public.track_feed_scores (final_score DESC);
CREATE INDEX IF NOT EXISTS idx_feed_scores_velocity
  ON public.track_feed_scores (velocity_24h DESC);

ALTER TABLE public.track_feed_scores ENABLE ROW LEVEL SECURITY;

-- ─── 3. Smart Feed RPC ─────────────────────────────────────

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
BEGIN
  -- Load config
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';

  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  -- Get following list for 'following' stream
  IF p_stream = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM public.follows
    WHERE follower_id = p_user_id;

    IF v_following_ids IS NULL OR array_length(v_following_ids, 1) IS NULL THEN
      RETURN; -- empty result for users who follow nobody
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
    -- Author profile
    p.username AS profile_username,
    p.avatar_url AS profile_avatar_url,
    p.display_name AS profile_display_name,
    -- Author tier
    COALESCE(fus.tier, 'newcomer') AS author_tier,
    rt.icon AS author_tier_icon,
    rt.color AS author_tier_color,
    COALESCE(p.is_verified, false) AS author_verified,
    -- Genre
    g.name_ru AS genre_name_ru,
    -- Feed scoring
    COALESCE(fs.final_score, 0) AS feed_score,
    COALESCE(fs.velocity_24h, 0) AS feed_velocity,
    -- Boost info
    (bt.id IS NOT NULL AND bt.expires_at > now()) AS is_boosted,
    bt.expires_at AS boost_expires_at,
    -- Quality
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
    -- Exclude blocked users
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE ub.user_id = t.user_id
        AND (ub.expires_at IS NULL OR ub.expires_at > now())
    )
    -- Genre filter
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    -- Stream filters
    AND (
      CASE p_stream
        WHEN 'following' THEN t.user_id = ANY(v_following_ids)
        WHEN 'trending' THEN
          COALESCE(t.plays_count, 0) >= COALESCE((v_qg->>'min_plays_for_trending')::int, 5)
          AND COALESCE(tqs.quality_score, 5) >= COALESCE((v_qg->>'min_score_for_trending')::numeric, 3.0)
        WHEN 'deep' THEN
          COALESCE(t.plays_count, 0) < 20
          AND t.created_at > now() - interval '14 days'
        ELSE true -- 'main' and 'fresh' show all
      END
    )
    -- Duration gate
    AND COALESCE(t.duration, 0) >= COALESCE((v_qg->>'min_duration_sec')::int, 30)
    -- Not spam
    AND COALESCE(fs.is_spam, false) = false
  ORDER BY
    CASE p_stream
      -- Main: smart score with time decay
      WHEN 'main' THEN
        COALESCE(fs.final_score, 0) *
        POWER(0.5, EXTRACT(EPOCH FROM (now() - t.created_at)) / 3600 / v_half_life)
        + CASE WHEN bt.id IS NOT NULL THEN 100 ELSE 0 END
      -- Trending: velocity (speed of engagement growth)
      WHEN 'trending' THEN COALESCE(fs.velocity_24h, 0)
      -- Fresh: newest first
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM t.created_at)
      -- Following: newest first
      WHEN 'following' THEN EXTRACT(EPOCH FROM t.created_at)
      -- Deep: random-ish underrated gems
      WHEN 'deep' THEN random() * 100 + COALESCE(tqs.quality_score, 5) * 10
      ELSE EXTRACT(EPOCH FROM t.created_at)
    END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ─── 4. Score calculation function ──────────────────────────

CREATE OR REPLACE FUNCTION public.recalculate_feed_scores(
  p_track_id UUID DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_weights JSONB;
  v_decay JSONB;
  v_tier_weights JSONB;
  v_qg JSONB;
  v_count INTEGER := 0;
  v_half_life NUMERIC;
  rec RECORD;
BEGIN
  SELECT value INTO v_weights FROM feed_config WHERE key = 'ranking_weights';
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_tier_weights FROM feed_config WHERE key = 'tier_weights';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';

  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  FOR rec IN
    SELECT t.id AS track_id,
           COALESCE(t.likes_count, 0) AS likes,
           COALESCE(t.plays_count, 0) AS plays,
           (SELECT COUNT(*) FROM public.track_comments tc WHERE tc.track_id = t.id) AS comments,
           COALESCE(t.shares_count, 0) AS shares,
           (SELECT COUNT(*) FROM public.playlist_tracks pt WHERE pt.track_id = t.id) AS saves,
           t.created_at,
           COALESCE(tqs.quality_score, 5) AS quality,
           -- Velocity: engagement in last 24h
           (SELECT COUNT(*) FROM public.track_likes tl
            WHERE tl.track_id = t.id AND tl.created_at > now() - interval '1 hour') AS likes_1h,
           (SELECT COUNT(*) FROM public.track_likes tl
            WHERE tl.track_id = t.id AND tl.created_at > now() - interval '24 hours') AS likes_24h
    FROM public.tracks t
    LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
    WHERE t.is_public = true AND t.status = 'completed'
      AND (p_track_id IS NULL OR t.id = p_track_id)
      AND t.created_at > now() - interval '30 days'
  LOOP
    INSERT INTO public.track_feed_scores (
      track_id, raw_engagement, weighted_engagement,
      velocity_1h, velocity_24h, time_decay_factor,
      final_score, is_spam, calculated_at
    ) VALUES (
      rec.track_id,
      -- Raw engagement
      rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
      rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
      rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
      rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
      rec.saves * COALESCE((v_weights->>'saves')::numeric, 10),
      -- Weighted (with quality)
      (rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
       rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
       rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
       rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
       rec.saves * COALESCE((v_weights->>'saves')::numeric, 10))
      * GREATEST(rec.quality / 10.0, 0.1),
      -- Velocity 1h
      rec.likes_1h * 10,
      -- Velocity 24h
      rec.likes_24h,
      -- Time decay
      POWER(0.5, EXTRACT(EPOCH FROM (now() - rec.created_at)) / 3600 / v_half_life),
      -- Final score
      (rec.likes * COALESCE((v_weights->>'likes')::numeric, 5) +
       rec.plays * COALESCE((v_weights->>'plays')::numeric, 1) +
       rec.comments * COALESCE((v_weights->>'comments')::numeric, 8) +
       rec.shares * COALESCE((v_weights->>'shares')::numeric, 12) +
       rec.saves * COALESCE((v_weights->>'saves')::numeric, 10))
      * GREATEST(rec.quality / 10.0, 0.1)
      * POWER(0.5, EXTRACT(EPOCH FROM (now() - rec.created_at)) / 3600 / v_half_life),
      -- Spam check
      rec.quality < COALESCE((v_qg->>'spam_threshold')::numeric, 1.0),
      now()
    )
    ON CONFLICT (track_id) DO UPDATE SET
      raw_engagement = EXCLUDED.raw_engagement,
      weighted_engagement = EXCLUDED.weighted_engagement,
      velocity_1h = EXCLUDED.velocity_1h,
      velocity_24h = EXCLUDED.velocity_24h,
      time_decay_factor = EXCLUDED.time_decay_factor,
      final_score = EXCLUDED.final_score,
      is_spam = EXCLUDED.is_spam,
      calculated_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─── 5. Initial score calculation ───────────────────────────
-- Run once to populate scores for existing tracks
SELECT public.recalculate_feed_scores();
