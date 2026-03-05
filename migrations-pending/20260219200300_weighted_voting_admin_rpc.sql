-- =============================================================
-- ULTIMATE VOTING ARCHITECTURE — Admin RPC Functions
-- =============================================================

-- admin_get_voting_dashboard
CREATE OR REPLACE FUNCTION public.admin_get_voting_dashboard()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_count INTEGER;
  v_votes_today INTEGER;
  v_flagged_count INTEGER;
  v_ending_soon INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  SELECT COUNT(*) INTO v_active_count FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at > now();
  SELECT COUNT(*) INTO v_votes_today FROM weighted_votes WHERE created_at > CURRENT_DATE;
  SELECT COUNT(*) INTO v_flagged_count FROM weighted_votes WHERE fraud_multiplier < 0.5;
  SELECT COUNT(*) INTO v_ending_soon FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at BETWEEN now() AND now() + interval '24 hours';

  RETURN jsonb_build_object(
    'active_count', v_active_count,
    'votes_today', v_votes_today,
    'flagged_count', v_flagged_count,
    'ending_soon', v_ending_soon
  );
END;
$$;

-- admin_get_active_votings
CREATE OR REPLACE FUNCTION public.admin_get_active_votings(
  p_filter TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'voting_ends_at',
  p_page INTEGER DEFAULT 1,
  p_per_page INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset INTEGER;
  v_tracks JSONB;
  v_total INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  v_offset := (p_page - 1) * p_per_page;

  SELECT COUNT(*) INTO v_total FROM tracks WHERE moderation_status = 'voting' AND voting_ends_at > now();

  SELECT jsonb_agg(sub) INTO v_tracks FROM (
    SELECT t.id, t.title, t.cover_url, t.user_id, t.voting_ends_at,
      COALESCE(t.weighted_likes_sum, 0) AS weighted_likes,
      COALESCE(t.weighted_dislikes_sum, 0) AS weighted_dislikes,
      CASE WHEN (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)) > 0
        THEN (COALESCE(t.weighted_likes_sum, 0) / (COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0)))::NUMERIC
        ELSE 0 END AS approval_rate
    FROM tracks t
    WHERE t.moderation_status = 'voting' AND t.voting_ends_at > now()
    ORDER BY
      CASE WHEN p_sort = 'voting_ends_at' THEN t.voting_ends_at END ASC NULLS LAST,
      CASE WHEN p_sort = 'total_weight' THEN COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0) END DESC NULLS LAST,
      CASE WHEN p_sort = 'approval_rate' THEN COALESCE(t.weighted_likes_sum, 0) / NULLIF(COALESCE(t.weighted_likes_sum, 0) + COALESCE(t.weighted_dislikes_sum, 0), 0) END DESC NULLS LAST
    LIMIT p_per_page OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object('tracks', COALESCE(v_tracks, '[]'::jsonb), 'total', v_total);
END;
$$;

-- admin_get_flagged_votes
CREATE OR REPLACE FUNCTION public.admin_get_flagged_votes(p_page INTEGER DEFAULT 1, p_per_page INTEGER DEFAULT 20)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset INTEGER;
  v_rows JSONB;
  v_total INTEGER;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  v_offset := (p_page - 1) * p_per_page;

  SELECT COUNT(*) INTO v_total FROM weighted_votes WHERE fraud_multiplier < 0.5;

  SELECT jsonb_agg(row_to_json(wv)) INTO v_rows
  FROM (
    SELECT id, track_id, user_id, vote_type, fraud_multiplier, created_at
    FROM weighted_votes
    WHERE fraud_multiplier < 0.5
    ORDER BY created_at DESC
    LIMIT p_per_page OFFSET v_offset
  ) wv;

  RETURN jsonb_build_object('votes', COALESCE(v_rows, '[]'::jsonb), 'total', v_total);
END;
$$;

-- admin_annul_vote
CREATE OR REPLACE FUNCTION public.admin_annul_vote(p_vote_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  INSERT INTO vote_audit_log (vote_id, action, details)
  SELECT p_vote_id, 'revoke', jsonb_build_object('admin_annul', true, 'reason', p_reason);

  DELETE FROM weighted_votes WHERE id = p_vote_id;
END;
$$;

-- admin_end_voting_early
CREATE OR REPLACE FUNCTION public.admin_end_voting_early(p_track_id UUID, p_result TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  RETURN public.resolve_track_voting(p_track_id, p_result);
END;
$$;
