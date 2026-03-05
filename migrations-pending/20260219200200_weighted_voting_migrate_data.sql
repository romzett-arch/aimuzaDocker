-- =============================================================
-- ULTIMATE VOTING ARCHITECTURE — Phase 7: Data Migration
-- Перенос track_votes → weighted_votes, создание voter_profiles
-- =============================================================

-- 1. Перенести голоса из track_votes в weighted_votes (weight=1.0)
INSERT INTO public.weighted_votes (track_id, user_id, vote_type, raw_weight, fraud_multiplier, combo_bonus, final_weight, created_at)
SELECT tv.track_id, tv.user_id, tv.vote_type, 1.0, 1.0, 0.0, 1.0, tv.created_at
FROM public.track_votes tv
WHERE NOT EXISTS (
  SELECT 1 FROM public.weighted_votes wv
  WHERE wv.track_id = tv.track_id AND wv.user_id = tv.user_id
)
ON CONFLICT (track_id, user_id) DO NOTHING;

-- 2. Создать voter_profiles для всех голосовавших (только существующие в auth.users)
INSERT INTO public.voter_profiles (user_id, votes_cast_total, votes_cast_30d, voter_rank, updated_at)
SELECT DISTINCT tv.user_id, 0, 0, 'scout', now()
FROM public.track_votes tv
JOIN auth.users u ON u.id = tv.user_id
WHERE NOT EXISTS (SELECT 1 FROM public.voter_profiles vp WHERE vp.user_id = tv.user_id)
ON CONFLICT (user_id) DO NOTHING;

-- 3. Обновить votes_cast_total в voter_profiles по данным weighted_votes
WITH counts AS (
  SELECT user_id, COUNT(*) AS cnt
  FROM public.weighted_votes
  GROUP BY user_id
)
UPDATE public.voter_profiles vp SET
  votes_cast_total = counts.cnt,
  updated_at = now()
FROM counts
WHERE vp.user_id = counts.user_id;

-- 4. Агрегировать weighted_votes в tracks (weighted_likes_sum, weighted_dislikes_sum)
SELECT public.aggregate_votes_to_tracks();
