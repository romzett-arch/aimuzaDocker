-- Fix get_smart_feed: use is_active/expires_at instead of status/ends_at for boost check
CREATE OR REPLACE FUNCTION public.get_smart_feed(
  p_user_id uuid DEFAULT NULL::uuid,
  p_stream text DEFAULT 'main'::text,
  p_genre_id uuid DEFAULT NULL::uuid,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 20
)
RETURNS TABLE(
  id uuid, title text, description text, audio_url text, cover_url text,
  duration integer, user_id uuid, genre_id uuid, is_public boolean,
  likes_count integer, plays_count integer, comments_count integer,
  shares_count integer, saves_count integer, status text,
  created_at timestamp with time zone,
  profile_username text, profile_avatar_url text, profile_display_name text,
  author_tier text, author_tier_icon text, author_tier_color text,
  author_verified boolean, genre_name_ru text,
  feed_score numeric, feed_velocity numeric,
  is_boosted boolean, boost_expires_at timestamp with time zone,
  quality_score numeric
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_decay JSONB;
  v_qg JSONB;
  v_following_ids UUID[];
  v_half_life NUMERIC;
BEGIN
  SELECT value INTO v_decay FROM feed_config WHERE key = 'time_decay';
  SELECT value INTO v_qg FROM feed_config WHERE key = 'quality_gate';
  v_half_life := COALESCE((v_decay->>'half_life_hours')::numeric, 48);

  IF p_stream = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM public.follows WHERE follower_id = p_user_id;
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
    SELECT bt2.id, bt2.expires_at
    FROM public.track_promotions bt2
    WHERE bt2.track_id = t.id
      AND bt2.is_active = true
      AND bt2.expires_at > now()
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
      WHEN 'trending' THEN COALESCE(fs.velocity_24h, 0)
      WHEN 'fresh' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'following' THEN EXTRACT(EPOCH FROM t.created_at)
      WHEN 'deep' THEN random() * 100 + COALESCE(tqs.quality_score, 5) * 10
      ELSE EXTRACT(EPOCH FROM t.created_at)
    END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$function$;

-- Sync admin_stop_promotion: also set old status column
CREATE OR REPLACE FUNCTION public.admin_stop_promotion(p_promotion_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')
  ) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RETURN json_build_object('success', false, 'error', 'Доступ запрещён');
  END IF;

  UPDATE public.track_promotions
  SET is_active = false, status = 'expired'
  WHERE id = p_promotion_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Промо не найдено');
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

-- Sync deactivate_expired_promotions: also set old status column
CREATE OR REPLACE FUNCTION public.deactivate_expired_promotions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.track_promotions
  SET is_active = false, status = 'expired'
  WHERE is_active = true AND expires_at < now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Fix existing data: sync status for already-stopped promotions
UPDATE public.track_promotions
SET status = 'expired'
WHERE is_active = false AND status = 'active';
