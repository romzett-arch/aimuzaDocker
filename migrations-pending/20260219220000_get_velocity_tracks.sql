-- get_velocity_tracks — TOP-N треков по скорости прироста голосов за последний час
-- Сравнивает текущий weighted_likes_sum с снапшотом ~1ч назад из voting_snapshots

CREATE OR REPLACE FUNCTION public.get_velocity_tracks(p_limit INTEGER DEFAULT 5)
RETURNS TABLE(
  track_id UUID,
  title TEXT,
  cover_url TEXT,
  audio_url TEXT,
  user_id UUID,
  weighted_likes_now NUMERIC,
  weighted_likes_1h_ago NUMERIC,
  velocity_delta NUMERIC,
  username TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH current_stats AS (
    SELECT
      t.id AS track_id,
      COALESCE(t.weighted_likes_sum, 0)::NUMERIC AS weighted_likes_now
    FROM tracks t
    WHERE (t.weighted_likes_sum + COALESCE(t.weighted_dislikes_sum, 0)) > 0
  ),
  old_snapshots AS (
    SELECT DISTINCT ON (vs.track_id)
      vs.track_id,
      vs.weighted_likes AS weighted_likes_1h_ago
    FROM voting_snapshots vs
    WHERE vs.snapshot_at <= now() - interval '50 min'
      AND vs.snapshot_at >= now() - interval '2 hours'
    ORDER BY vs.track_id, vs.snapshot_at DESC
  ),
  combined AS (
    SELECT
      cs.track_id,
      cs.weighted_likes_now,
      COALESCE(os.weighted_likes_1h_ago, 0)::NUMERIC AS weighted_likes_1h_ago,
      (cs.weighted_likes_now - COALESCE(os.weighted_likes_1h_ago, 0))::NUMERIC AS velocity_delta
    FROM current_stats cs
    LEFT JOIN old_snapshots os ON os.track_id = cs.track_id
  )
  SELECT
    t.id AS track_id,
    t.title,
    t.cover_url,
    t.audio_url,
    t.user_id,
    c.weighted_likes_now,
    c.weighted_likes_1h_ago,
    c.velocity_delta,
    pp.username
  FROM combined c
  JOIN tracks t ON t.id = c.track_id
  LEFT JOIN profiles_public pp ON pp.user_id = t.user_id
  ORDER BY c.velocity_delta DESC NULLS LAST, c.weighted_likes_now DESC
  LIMIT p_limit;
END;
$$;
