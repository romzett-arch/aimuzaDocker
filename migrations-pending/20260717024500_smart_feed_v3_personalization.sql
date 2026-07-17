-- Smart Feed V3: explainable personalization, diversity and negative feedback.

CREATE TABLE IF NOT EXISTS public.feed_feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  track_id UUID,
  author_id UUID,
  feedback_type TEXT NOT NULL CHECK (feedback_type IN ('not_interested', 'hide_author')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (feedback_type = 'not_interested' AND track_id IS NOT NULL)
    OR (feedback_type = 'hide_author' AND author_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS feed_feedback_user_track_unique
  ON public.feed_feedback (user_id, feedback_type, track_id)
  WHERE track_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS feed_feedback_user_author_unique
  ON public.feed_feedback (user_id, feedback_type, author_id)
  WHERE author_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS feed_feedback_user_lookup
  ON public.feed_feedback (user_id, feedback_type);

ALTER TABLE public.feed_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own feed feedback" ON public.feed_feedback;
CREATE POLICY "Users manage own feed feedback"
  ON public.feed_feedback
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

GRANT SELECT, INSERT, DELETE ON public.feed_feedback TO authenticated;

INSERT INTO public.feed_config (key, value, label, description)
VALUES (
  'personalization_mix',
  '{"following":45,"taste":25,"discovery":15,"deep":10,"trending":5,"max_tracks_per_author":2}'::jsonb,
  'Состав персональной ленты',
  'Целевые доли источников в процентах и ограничение повторов одного автора.'
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    label = EXCLUDED.label,
    description = EXCLUDED.description,
    updated_at = now();

CREATE OR REPLACE FUNCTION public.record_feed_feedback(
  p_track_id UUID,
  p_author_id UUID,
  p_feedback_type TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  actor_id UUID := auth.uid();
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_feedback_type NOT IN ('not_interested', 'hide_author') THEN
    RAISE EXCEPTION 'Unsupported feedback type';
  END IF;

  IF p_feedback_type = 'not_interested' AND p_track_id IS NULL THEN
    RAISE EXCEPTION 'Track is required';
  END IF;

  IF p_feedback_type = 'hide_author' AND p_author_id IS NULL THEN
    RAISE EXCEPTION 'Author is required';
  END IF;

  IF p_feedback_type = 'not_interested' THEN
    INSERT INTO public.feed_feedback (user_id, track_id, author_id, feedback_type)
    VALUES (actor_id, p_track_id, p_author_id, p_feedback_type)
    ON CONFLICT (user_id, feedback_type, track_id)
      WHERE track_id IS NOT NULL
    DO NOTHING;
  ELSE
    INSERT INTO public.feed_feedback (user_id, track_id, author_id, feedback_type)
    VALUES (actor_id, p_track_id, p_author_id, p_feedback_type)
    ON CONFLICT (user_id, feedback_type, author_id)
      WHERE author_id IS NOT NULL
    DO NOTHING;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.record_feed_feedback(UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_smart_feed_v3(
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
  quality_score NUMERIC,
  author_sub_tier TEXT,
  author_sub_badge TEXT,
  recommendation_reason TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH
settings AS (
  SELECT
    COALESCE((SELECT (value->>'half_life_hours')::numeric FROM public.feed_config WHERE key = 'time_decay'), 48) AS half_life,
    COALESCE((SELECT (value->>'min_duration_sec')::integer FROM public.feed_config WHERE key = 'quality_gate'), 30) AS min_duration,
    COALESCE((SELECT (value->>'min_plays_for_trending')::integer FROM public.feed_config WHERE key = 'quality_gate'), 5) AS min_trending_plays,
    COALESCE((SELECT (value->>'min_score_for_trending')::numeric FROM public.feed_config WHERE key = 'quality_gate'), 3) AS min_trending_quality,
    COALESCE((SELECT (value->>'following')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 45) AS following_pct,
    COALESCE((SELECT (value->>'taste')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 25) AS taste_pct,
    COALESCE((SELECT (value->>'discovery')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 15) AS discovery_pct,
    COALESCE((SELECT (value->>'deep')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 10) AS deep_pct,
    COALESCE((SELECT (value->>'trending')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 5) AS trending_pct,
    COALESCE((SELECT (value->>'max_tracks_per_author')::integer FROM public.feed_config WHERE key = 'personalization_mix'), 2) AS max_per_author
),
genre_signals AS (
  SELECT signal.genre_id, SUM(signal.weight)::numeric AS affinity
  FROM (
    SELECT t.genre_id, 3::numeric AS weight
    FROM public.track_likes tl
    JOIN public.tracks t ON t.id = tl.track_id
    WHERE p_user_id IS NOT NULL AND tl.user_id = p_user_id AND t.genre_id IS NOT NULL
    UNION ALL
    SELECT t.genre_id, 4::numeric AS weight
    FROM public.playlists pl
    JOIN public.playlist_tracks pt ON pt.playlist_id = pl.id
    JOIN public.tracks t ON t.id = pt.track_id
    WHERE p_user_id IS NOT NULL AND pl.user_id = p_user_id AND t.genre_id IS NOT NULL
    UNION ALL
    SELECT t.genre_id, 1::numeric AS weight
    FROM public.user_listened_tracks ult
    JOIN public.tracks t ON t.id = ult.track_id
    WHERE p_user_id IS NOT NULL AND ult.user_id = p_user_id AND t.genre_id IS NOT NULL
  ) signal
  GROUP BY signal.genre_id
),
candidate_base AS (
  SELECT
    t.id, t.title, t.description, t.audio_url, t.cover_url,
    t.duration, t.user_id, t.genre_id, t.is_public,
    COALESCE(t.likes_count, 0)::integer AS likes_count,
    COALESCE(t.plays_count, 0)::integer AS plays_count,
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
    COALESCE(fs.final_score, 0)::numeric AS base_feed_score,
    COALESCE(fs.velocity_24h, 0)::numeric AS feed_velocity,
    (promotion.id IS NOT NULL) AS is_boosted,
    promotion.expires_at AS boost_expires_at,
    COALESCE(tqs.quality_score, 5)::numeric AS quality_score,
    sp.tier_key AS author_sub_tier,
    sp.badge_emoji AS author_sub_badge,
    EXISTS (
      SELECT 1 FROM public.user_follows uf
      WHERE p_user_id IS NOT NULL
        AND uf.follower_id = p_user_id
        AND uf.following_id = t.user_id
    ) AS is_following,
    COALESCE(gs.affinity, 0)::numeric AS genre_affinity
  FROM public.tracks t
  CROSS JOIN settings cfg
  LEFT JOIN public.profiles p ON p.user_id = t.user_id
  LEFT JOIN public.genres g ON g.id = t.genre_id
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = t.user_id
  LEFT JOIN public.reputation_tiers rt ON rt.key = COALESCE(fus.tier, 'newcomer')
  LEFT JOIN public.track_feed_scores fs ON fs.track_id = t.id
  LEFT JOIN public.track_quality_scores tqs ON tqs.track_id = t.id
  LEFT JOIN genre_signals gs ON gs.genre_id = t.genre_id
  LEFT JOIN LATERAL (
    SELECT tp.id, tp.expires_at
    FROM public.track_promotions tp
    WHERE tp.track_id = t.id
      AND tp.is_active = true
      AND tp.expires_at > now()
    ORDER BY tp.expires_at DESC
    LIMIT 1
  ) promotion ON true
  LEFT JOIN LATERAL (
    SELECT us.plan_id
    FROM public.user_subscriptions us
    WHERE us.user_id = t.user_id
      AND us.status = 'active'
      AND us.current_period_end > now()
    ORDER BY us.created_at DESC
    LIMIT 1
  ) author_subscription ON true
  LEFT JOIN public.subscription_plans sp ON sp.id = author_subscription.plan_id
  WHERE t.is_public = true
    AND t.status = 'completed'
    AND COALESCE(t.is_in_my_releases, false) = false
    AND COALESCE(t.duration, 0) >= cfg.min_duration
    AND COALESCE(fs.is_spam, false) = false
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    AND (p_user_id IS NULL OR t.user_id <> p_user_id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.feed_feedback ff
      WHERE p_user_id IS NOT NULL
        AND ff.user_id = p_user_id
        AND (
          (ff.feedback_type = 'not_interested' AND ff.track_id = t.id)
          OR (ff.feedback_type = 'hide_author' AND ff.author_id = t.user_id)
        )
    )
),
classified AS (
  SELECT
    cb.*,
    CASE
      WHEN p_stream = 'following' THEN 'following'
      WHEN p_stream = 'trending' THEN 'trending'
      WHEN p_stream = 'fresh' THEN 'fresh'
      WHEN p_stream = 'deep' THEN 'deep'
      WHEN cb.is_following THEN 'following'
      WHEN cb.genre_affinity > 0 THEN 'taste'
      WHEN cb.plays_count < 20 AND cb.created_at > now() - interval '14 days' THEN 'deep'
      WHEN cb.feed_velocity > 0 OR cb.plays_count >= cfg.min_trending_plays THEN 'trending'
      ELSE 'discovery'
    END AS reason_key,
    CASE
      WHEN p_stream = 'following' THEN 'Из ваших подписок'
      WHEN p_stream = 'trending' THEN 'Сейчас набирает популярность'
      WHEN p_stream = 'fresh' THEN 'Новая публикация'
      WHEN p_stream = 'deep' THEN 'Недооценённая находка'
      WHEN cb.is_following THEN 'Из ваших подписок'
      WHEN cb.genre_affinity > 0 THEN 'Похожий на то, что вам нравится'
      WHEN cb.plays_count < 20 AND cb.created_at > now() - interval '14 days' THEN 'Недооценённая находка'
      WHEN cb.feed_velocity > 0 OR cb.plays_count >= cfg.min_trending_plays THEN 'Сейчас набирает популярность'
      ELSE 'Новый автор для вас'
    END AS recommendation_reason,
    (
      cb.base_feed_score
      * POWER(0.5, EXTRACT(EPOCH FROM (now() - cb.created_at)) / 3600 / cfg.half_life)
      + CASE WHEN cb.is_boosted THEN 100 ELSE 0 END
      + CASE WHEN cb.is_following THEN 120 ELSE 0 END
      + cb.genre_affinity * 20
      + cb.feed_velocity * 2
      + CASE WHEN cb.plays_count < 20 AND cb.created_at > now() - interval '14 days' THEN 15 ELSE 0 END
    )::numeric AS ranking_score
  FROM candidate_base cb
  CROSS JOIN settings cfg
  WHERE
    CASE p_stream
      WHEN 'following' THEN cb.is_following
      WHEN 'trending' THEN cb.plays_count >= cfg.min_trending_plays
        AND cb.quality_score >= cfg.min_trending_quality
      WHEN 'deep' THEN cb.plays_count < 20
        AND cb.created_at > now() - interval '14 days'
      ELSE true
    END
),
bucket_ranked AS (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY c.reason_key
      ORDER BY
        CASE p_stream
          WHEN 'fresh' THEN EXTRACT(EPOCH FROM c.created_at)
          WHEN 'following' THEN EXTRACT(EPOCH FROM c.created_at)
          WHEN 'trending' THEN c.feed_velocity
          WHEN 'deep' THEN c.quality_score * 10 - c.plays_count
          ELSE c.ranking_score
        END DESC,
        c.created_at DESC
    ) AS bucket_rank
  FROM classified c
),
quota_marked AS (
  SELECT
    br.*,
    CASE
      WHEN p_stream <> 'main' THEN 0
      WHEN br.reason_key = 'following'
        AND br.bucket_rank <= CEIL((p_offset + p_limit) * cfg.following_pct / 100.0) THEN 0
      WHEN br.reason_key = 'taste'
        AND br.bucket_rank <= CEIL((p_offset + p_limit) * cfg.taste_pct / 100.0) THEN 0
      WHEN br.reason_key = 'discovery'
        AND br.bucket_rank <= CEIL((p_offset + p_limit) * cfg.discovery_pct / 100.0) THEN 0
      WHEN br.reason_key = 'deep'
        AND br.bucket_rank <= CEIL((p_offset + p_limit) * cfg.deep_pct / 100.0) THEN 0
      WHEN br.reason_key = 'trending'
        AND br.bucket_rank <= CEIL((p_offset + p_limit) * cfg.trending_pct / 100.0) THEN 0
      ELSE 1
    END AS fallback_priority
  FROM bucket_ranked br
  CROSS JOIN settings cfg
),
diversified AS (
  SELECT
    qm.*,
    ROW_NUMBER() OVER (
      PARTITION BY qm.user_id
      ORDER BY qm.fallback_priority, qm.ranking_score DESC, qm.created_at DESC
    ) AS author_rank
  FROM quota_marked qm
),
ordered AS (
  SELECT d.*
  FROM diversified d
  CROSS JOIN settings cfg
  WHERE d.author_rank <= cfg.max_per_author
  ORDER BY
    d.fallback_priority,
    CASE p_stream
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM d.created_at)
      WHEN 'following' THEN EXTRACT(EPOCH FROM d.created_at)
      WHEN 'trending' THEN d.feed_velocity
      WHEN 'deep' THEN d.quality_score * 10 - d.plays_count
      ELSE d.ranking_score
    END DESC,
    d.created_at DESC
  LIMIT p_limit OFFSET p_offset
)
SELECT
  o.id, o.title, o.description, o.audio_url, o.cover_url,
  o.duration, o.user_id, o.genre_id, o.is_public,
  o.likes_count, o.plays_count, o.comments_count, o.shares_count, o.saves_count,
  o.status, o.created_at,
  o.profile_username, o.profile_avatar_url, o.profile_display_name,
  o.author_tier, o.author_tier_icon, o.author_tier_color, o.author_verified,
  o.genre_name_ru,
  o.ranking_score AS feed_score,
  o.feed_velocity,
  o.is_boosted, o.boost_expires_at, o.quality_score,
  o.author_sub_tier, o.author_sub_badge,
  o.recommendation_reason
FROM ordered o;
$function$;

GRANT EXECUTE ON FUNCTION public.get_smart_feed_v3(UUID, TEXT, UUID, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_smart_feed_v3(UUID, TEXT, UUID, INTEGER, INTEGER) TO anon;

