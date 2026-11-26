
-- Preserve legacy results while retiring public track voting.
CREATE TABLE public.retired_track_voting_history (
  track_id uuid PRIMARY KEY,
  history jsonb NOT NULL
);

ALTER TABLE public.retired_track_voting_history ENABLE ROW LEVEL SECURITY;

-- Serialize the final snapshot and state transition with in-flight track writes.
LOCK TABLE public.tracks IN SHARE ROW EXCLUSIVE MODE;

INSERT INTO public.retired_track_voting_history (track_id, history)
SELECT id, jsonb_build_object(
  'moderation_status', moderation_status, 'distribution_status', distribution_status,
  'forum_topic_id', forum_topic_id, 'is_public', is_public,
  'voting_round_id', voting_round_id, 'voting_type', voting_type,
  'voting_started_at', voting_started_at, 'voting_ends_at', voting_ends_at,
  'voting_result', voting_result,
  'voting_likes_count', voting_likes_count, 'voting_dislikes_count', voting_dislikes_count,
  'weighted_likes_sum', weighted_likes_sum, 'weighted_dislikes_sum', weighted_dislikes_sum,
  'chart_position', chart_position, 'chart_score', chart_score
)
FROM public.tracks
WHERE moderation_status = 'voting' OR distribution_status = 'voting'
   OR voting_round_id IS NOT NULL OR voting_type IS NOT NULL
   OR voting_started_at IS NOT NULL OR voting_ends_at IS NOT NULL OR voting_result IS NOT NULL
   OR COALESCE(voting_likes_count, 0) <> 0 OR COALESCE(voting_dislikes_count, 0) <> 0
   OR COALESCE(weighted_likes_sum, 0) <> 0 OR COALESCE(weighted_dislikes_sum, 0) <> 0
   OR chart_position IS NOT NULL OR chart_score IS NOT NULL;

UPDATE public.tracks AS track
SET moderation_status = CASE WHEN track.moderation_status = 'voting' THEN 'pending' ELSE track.moderation_status END,
    distribution_status = CASE
      WHEN track.distribution_status IS DISTINCT FROM 'voting' THEN track.distribution_status
      -- Uploaded tracks need moderation approval before entering distribution.
      WHEN track.source_type = 'uploaded' AND track.moderation_status IS DISTINCT FROM 'approved' THEN 'none'
      ELSE 'pending_moderation'
    END,
    is_public = CASE WHEN track.moderation_status = 'voting' THEN false ELSE track.is_public END,
    voting_round_id = NULL, voting_type = NULL, voting_started_at = NULL, voting_ends_at = NULL,
    voting_result = NULL, voting_likes_count = 0, voting_dislikes_count = 0,
    weighted_likes_sum = 0, weighted_dislikes_sum = 0, chart_position = NULL, chart_score = NULL
FROM public.retired_track_voting_history AS archive
WHERE track.id = archive.track_id;

ALTER TABLE public.tracks ADD CONSTRAINT tracks_voting_retired CHECK (
  moderation_status IS DISTINCT FROM 'voting' AND distribution_status IS DISTINCT FROM 'voting'
  AND voting_round_id IS NULL AND voting_type IS NULL
  AND voting_started_at IS NULL AND voting_ends_at IS NULL AND voting_result IS NULL
  AND COALESCE(voting_likes_count, 0) = 0 AND COALESCE(voting_dislikes_count, 0) = 0
  AND COALESCE(weighted_likes_sum, 0) = 0 AND COALESCE(weighted_dislikes_sum, 0) = 0
  AND chart_position IS NULL AND chart_score IS NULL
);

-- Retain the old signatures until all containers have switched to the new scheduler.
CREATE OR REPLACE FUNCTION public.calculate_chart_scores()
RETURNS void LANGUAGE sql SET search_path = public AS $$ SELECT NULL::void $$;

CREATE OR REPLACE FUNCTION public.update_voter_ranks()
RETURNS void LANGUAGE sql SET search_path = public AS $$ SELECT NULL::void $$;

CREATE OR REPLACE FUNCTION public.resolve_expired_votings()
RETURNS integer LANGUAGE sql SET search_path = public AS $$ SELECT 0 $$;

CREATE OR REPLACE FUNCTION public.aggregate_votes_to_tracks()
RETURNS integer LANGUAGE sql SET search_path = public AS $$ SELECT 0 $$;

-- A non-empty discussion category keeps its ID, URL, threads and their attachments.
UPDATE public.forum_categories AS category
SET name = 'Track discussions archive',
    name_ru = 'Архив обсуждений треков',
    description = NULL,
    description_ru = NULL,
    is_active = category.is_active AND (
      EXISTS (SELECT 1 FROM public.forum_topics WHERE category_id = category.id)
      OR EXISTS (SELECT 1 FROM public.forum_categories WHERE parent_id = category.id)
    ),
    updated_at = now()
WHERE category.slug = 'voting'
   OR category.id::text IN (SELECT value FROM public.settings WHERE key = 'forum_voting_category_id');

DELETE FROM public.settings
WHERE left(key, 7) = 'voting_' OR key IN ('forum_voting_category_id', 'forum_voting_category_slug');

UPDATE public.seo_metadata SET is_active = false WHERE page_key = 'voting';
UPDATE public.seo_robots_rules SET is_active = false
WHERE rtrim(path, '/') IN ('/voting', '/arena', '/chart', '/admin/voting');

REVOKE ALL ON TABLE public.retired_track_voting_history, public.track_votes,
  public.internal_votes, public.weighted_votes, public.vote_audit_log,
  public.voter_profiles, public.vote_combos, public.voting_snapshots,
  public.chart_entries, public.mv_voting_live
FROM PUBLIC, anon, authenticated, service_role, aimuza_gateway;

-- Match by name so archived overloads, when present, lose execute privileges too.
DO $$
DECLARE
  routine regprocedure;
BEGIN
  FOR routine IN
    SELECT oid::regprocedure FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname IN (
      'admin_annul_vote', 'admin_end_voting_early', 'admin_get_active_votings',
      'admin_get_flagged_votes', 'admin_get_voting_dashboard', 'admin_review_flagged_votes',
      'aggregate_votes_to_tracks', 'assess_vote_fraud', 'calculate_chart_scores',
      'cast_radio_vote_for_arena', 'cast_weighted_vote', 'cast_weighted_vote_debug',
      'check_voting_eligibility', 'close_voting_topic_on_rejection', 'create_voting_forum_topic',
      'get_my_weighted_vote', 'get_recent_voters', 'get_user_vote_weight', 'get_velocity_tracks',
      'get_voter_profile', 'get_voting_live_stats', 'refresh_track_voting_totals',
      'resolve_expired_votings', 'resolve_track_voting', 'resolve_track_voting_core', 'revoke_vote',
      'send_silk_release_to_voting', 'send_track_to_voting', 'take_voting_snapshot',
      'trg_refresh_track_voting_totals', 'update_voter_ranks'
    )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, aimuza_gateway', routine);
  END LOOP;
END;
$$;

-- Keep listener XP and reactions independent of the retired voting module.
CREATE OR REPLACE FUNCTION public.radio_award_listen_xp(
  p_user_id UUID, p_track_id UUID, p_listen_duration_sec INTEGER,
  p_track_duration_sec INTEGER, p_reaction TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL, p_ip_hash TEXT DEFAULT NULL,
  p_is_afk_verified BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config JSONB; v_listen_percent NUMERIC; v_xp_earned INTEGER := 0;
  v_xp_today INTEGER; v_daily_cap INTEGER; v_min_percent NUMERIC;
  v_xp_per_listen NUMERIC; v_caller UUID;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL OR v_caller <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tracks WHERE id = p_track_id AND status = 'completed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'track_not_available');
  END IF;

  SELECT value INTO v_config FROM public.radio_config WHERE key = 'listen_to_earn';
  v_daily_cap := COALESCE((v_config->>'daily_cap')::INTEGER, 100);
  v_min_percent := COALESCE((v_config->>'min_listen_percent')::NUMERIC, 60);
  v_xp_per_listen := COALESCE((v_config->>'xp_per_listen')::NUMERIC, 2);
  p_track_duration_sec := GREATEST(p_track_duration_sec, 1);
  v_listen_percent := LEAST(100, GREATEST(0, p_listen_duration_sec::NUMERIC / p_track_duration_sec * 100));

  SELECT COALESCE(SUM(xp_earned), 0)::INTEGER INTO v_xp_today
  FROM public.radio_listens WHERE user_id = p_user_id AND created_at >= CURRENT_DATE;
  IF v_listen_percent >= v_min_percent AND v_xp_today < v_daily_cap THEN
    v_xp_earned := LEAST(
      GREATEST(1, round(v_xp_per_listen * v_listen_percent / 100)::INTEGER),
      v_daily_cap - v_xp_today
    );
  END IF;

  INSERT INTO public.radio_listens(user_id, track_id, session_id, listen_duration_sec,
    track_duration_sec, listen_percent, xp_earned, reaction, ip_hash, is_afk_verified)
  VALUES (p_user_id, p_track_id, p_session_id, p_listen_duration_sec,
    p_track_duration_sec, v_listen_percent, v_xp_earned, p_reaction, p_ip_hash, p_is_afk_verified);

  IF v_xp_earned > 0 THEN PERFORM public.fn_add_xp(p_user_id, v_xp_earned, 'music', false); END IF;
  v_xp_today := v_xp_today + v_xp_earned;

  RETURN jsonb_build_object('ok', true, 'xp_earned', v_xp_earned,
    'listen_percent', v_listen_percent, 'xp_today', v_xp_today,
    'daily_cap', v_daily_cap,
    'listens_today', (SELECT count(*) FROM public.radio_listens WHERE user_id=p_user_id AND created_at>=CURRENT_DATE),
    'diminishing', v_xp_today >= v_daily_cap);
END;
$$;
