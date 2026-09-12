-- Separate an author's placement preview from real promotion delivery and analytics.

CREATE OR REPLACE FUNCTION public.record_track_promotion_event(
  p_track_id UUID,
  p_event_type TEXT,
  p_surface TEXT,
  p_visitor_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_promotion_id UUID;
  v_owner_id UUID;
  v_event_id UUID;
BEGIN
  IF p_event_type NOT IN ('impression', 'open', 'play') THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_event_type');
  END IF;

  IF p_surface NOT IN ('shelf', 'feed', 'track', 'radio') THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_surface');
  END IF;

  IF p_visitor_key IS NULL OR char_length(p_visitor_key) NOT BETWEEN 8 AND 128 THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'invalid_visitor_key');
  END IF;

  SELECT tp.id, t.user_id
  INTO v_promotion_id, v_owner_id
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE tp.track_id = p_track_id
    AND tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
    AND COALESCE(t.is_in_my_releases, false) = false
  ORDER BY tp.expires_at DESC
  LIMIT 1;

  IF v_promotion_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'error', 'promotion_not_active');
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() = v_owner_id THEN
    RETURN jsonb_build_object('recorded', false, 'owner_preview', true);
  END IF;

  INSERT INTO public.track_promotion_events (
    promotion_id, user_id, visitor_key, event_type, surface
  )
  VALUES (
    v_promotion_id, auth.uid(), p_visitor_key, p_event_type, p_surface
  )
  ON CONFLICT (promotion_id, visitor_key, event_type, surface) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'duplicate', true);
  END IF;

  UPDATE public.track_promotions
  SET
    impressions_count = COALESCE(impressions_count, 0)
      + CASE WHEN p_event_type = 'impression' THEN 1 ELSE 0 END,
    clicks_count = COALESCE(clicks_count, 0)
      + CASE WHEN p_event_type IN ('open', 'play') THEN 1 ELSE 0 END,
    shelf_impressions_count = shelf_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'shelf' THEN 1 ELSE 0 END,
    feed_impressions_count = feed_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'feed' THEN 1 ELSE 0 END,
    radio_impressions_count = radio_impressions_count
      + CASE WHEN p_event_type = 'impression' AND p_surface = 'radio' THEN 1 ELSE 0 END,
    opens_count = opens_count
      + CASE WHEN p_event_type = 'open' THEN 1 ELSE 0 END,
    plays_count = plays_count
      + CASE WHEN p_event_type = 'play' THEN 1 ELSE 0 END
  WHERE id = v_promotion_id;

  RETURN jsonb_build_object('recorded', true, 'promotion_id', v_promotion_id);
END;
$$;

REVOKE ALL ON FUNCTION public.record_track_promotion_event(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_track_promotion_event(UUID, TEXT, TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_boosted_tracks(p_limit INTEGER DEFAULT 5)
RETURNS TABLE (
  track_id UUID,
  promotion_id UUID,
  boost_type TEXT,
  expires_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT tp.track_id, tp.id, tp.boost_type, tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
    AND t.audio_url IS NOT NULL
    AND COALESCE(t.is_in_my_releases, false) = false
    AND (auth.uid() IS NULL OR t.user_id <> auth.uid())
  ORDER BY md5(
    tp.id::TEXT || ':' ||
    floor(extract(epoch FROM now()) / 300)::BIGINT::TEXT
  )
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 5), 20));
$$;

REVOKE ALL ON FUNCTION public.get_boosted_tracks(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_active_track_boosts()
RETURNS TABLE (
  track_id UUID,
  promotion_id UUID,
  boost_type TEXT,
  starts_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  impressions INTEGER,
  shelf_impressions INTEGER,
  feed_impressions INTEGER,
  radio_impressions INTEGER,
  opens INTEGER,
  plays INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    tp.track_id,
    tp.id,
    tp.boost_type,
    COALESCE(tp.starts_at, tp.created_at),
    tp.expires_at,
    COALESCE(tp.impressions_count, 0),
    COALESCE(tp.shelf_impressions_count, 0),
    COALESCE(tp.feed_impressions_count, 0),
    COALESCE(tp.radio_impressions_count, 0),
    COALESCE(tp.opens_count, 0),
    COALESCE(tp.plays_count, 0)
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE auth.uid() IS NOT NULL
    AND tp.user_id = auth.uid()
    AND tp.is_active = true
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
    AND t.audio_url IS NOT NULL
    AND COALESCE(t.is_in_my_releases, false) = false
  ORDER BY tp.expires_at ASC;
$$;

REVOKE ALL ON FUNCTION public.get_my_active_track_boosts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_active_track_boosts() TO authenticated;

CREATE OR REPLACE FUNCTION public.record_track_play(p_track_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_owner_id UUID;
BEGIN
  SELECT user_id INTO v_owner_id
  FROM public.tracks
  WHERE id = p_track_id;

  IF NOT FOUND OR (v_actor_id IS NOT NULL AND v_actor_id = v_owner_id) THEN
    RETURN;
  END IF;

  PERFORM set_config('app.bypass_track_protection', 'true', true);

  UPDATE public.tracks
  SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id;

  INSERT INTO public.track_daily_stats (track_id, date, plays_count)
  VALUES (p_track_id, CURRENT_DATE, 1)
  ON CONFLICT (track_id, date)
  DO UPDATE SET plays_count = track_daily_stats.plays_count + 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_track_play(UUID) TO authenticated, anon;

CREATE OR REPLACE FUNCTION public.record_feed_listen(p_track_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_owner_id UUID;
BEGIN
  IF v_actor_id IS NULL THEN
    RETURN;
  END IF;

  SELECT user_id INTO v_owner_id
  FROM public.tracks
  WHERE id = p_track_id;

  IF NOT FOUND OR v_actor_id = v_owner_id THEN
    RETURN;
  END IF;

  INSERT INTO public.user_listened_tracks (user_id, track_id)
  VALUES (v_actor_id, p_track_id)
  ON CONFLICT (user_id, track_id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_feed_listen(UUID) TO authenticated, anon;
