-- =============================================================
-- ULTIMATE VOTING — Security & Consistency Fixes
-- 1. RLS: запрет прямого INSERT/UPDATE/DELETE в weighted_votes (только через RPC)
-- 2. aggregate_votes_to_tracks: синхронизация voting_likes_count/dislikes_count
-- 3. mv_voting_live: поддержка REFRESH CONCURRENTLY (уже есть unique index)
-- =============================================================

-- 1. REVOKE прямого доступа к weighted_votes — голосование ТОЛЬКО через cast_weighted_vote/revoke_vote
-- Иначе пользователь может обойти fraud checks и вставить произвольный final_weight
REVOKE INSERT, UPDATE, DELETE ON public.weighted_votes FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.weighted_votes FROM anon;

-- SELECT оставляем — для чтения своих голосов
GRANT SELECT ON public.weighted_votes TO authenticated;
GRANT SELECT ON public.weighted_votes TO anon;

-- RPC вызываются с JWT — EXECUTE уже выдан при создании функций
-- cast_weighted_vote и revoke_vote работают как SECURITY DEFINER (обходят RLS)

-- 2. Обновить aggregate_votes_to_tracks — синхронизировать voting_likes_count, voting_dislikes_count
-- для совместимости с resolve-voting и Legacy UI (minVotes, totalVotes)
CREATE OR REPLACE FUNCTION public.aggregate_votes_to_tracks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INTEGER := 0;
  v_n INTEGER := 0;
BEGIN
  WITH agg AS (
    SELECT
      wv.track_id,
      SUM(CASE WHEN wv.vote_type IN ('like', 'superlike') THEN wv.final_weight ELSE 0 END) AS likes_sum,
      SUM(CASE WHEN wv.vote_type = 'dislike' THEN wv.final_weight ELSE 0 END) AS dislikes_sum,
      COUNT(*) FILTER (WHERE wv.vote_type IN ('like', 'superlike'))::INTEGER AS likes_count,
      COUNT(*) FILTER (WHERE wv.vote_type = 'dislike')::INTEGER AS dislikes_count
    FROM weighted_votes wv
    GROUP BY wv.track_id
  )
  UPDATE tracks t SET
    weighted_likes_sum = agg.likes_sum,
    weighted_dislikes_sum = agg.dislikes_sum,
    voting_likes_count = agg.likes_count,
    voting_dislikes_count = agg.dislikes_count
  FROM agg
  WHERE t.id = agg.track_id
  AND (
    COALESCE(t.weighted_likes_sum, 0) != agg.likes_sum
    OR COALESCE(t.weighted_dislikes_sum, 0) != agg.dislikes_sum
    OR COALESCE(t.voting_likes_count, 0) != agg.likes_count
    OR COALESCE(t.voting_dislikes_count, 0) != agg.dislikes_count
  );

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  -- Обнулить треки, у которых все голоса отозваны (нет строк в weighted_votes)
  UPDATE tracks t SET
    weighted_likes_sum = 0,
    weighted_dislikes_sum = 0,
    voting_likes_count = 0,
    voting_dislikes_count = 0
  WHERE (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)) > 0
  AND NOT EXISTS (SELECT 1 FROM weighted_votes wv WHERE wv.track_id = t.id);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_updated := v_updated + v_n;
  RETURN v_updated;
END;
$$;

-- 3. mv_voting_live: для REFRESH CONCURRENTLY нужен UNIQUE index — уже есть idx_mv_voting_live_track
-- Документация: использовать REFRESH MATERIALIZED VIEW CONCURRENTLY mv_voting_live;
-- get_voting_live_stats читает из weighted_votes напрямую — MV опционален для batch-запросов
