-- Voting module reliability and security hardening.
-- One voting round = one immutable round id. Current results are derived only
-- from active votes in the current round.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.tracks
  ADD COLUMN IF NOT EXISTS voting_round_id uuid;

ALTER TABLE public.weighted_votes
  ADD COLUMN IF NOT EXISTS voting_round_id uuid,
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.tracks t
SET voting_round_id = gen_random_uuid()
WHERE t.voting_round_id IS NULL
  AND (
    t.voting_started_at IS NOT NULL
    OR EXISTS (SELECT 1 FROM public.weighted_votes wv WHERE wv.track_id = t.id)
  );

UPDATE public.weighted_votes wv
SET voting_round_id = t.voting_round_id
FROM public.tracks t
WHERE t.id = wv.track_id
  AND wv.voting_round_id IS NULL;

ALTER TABLE public.weighted_votes
  ALTER COLUMN voting_round_id SET NOT NULL;

ALTER TABLE public.weighted_votes
  DROP CONSTRAINT IF EXISTS unique_user_track_weighted_vote;
DROP INDEX IF EXISTS public.unique_user_track_weighted_vote;
CREATE UNIQUE INDEX IF NOT EXISTS unique_user_track_voting_round
  ON public.weighted_votes(track_id, user_id, voting_round_id);
CREATE INDEX IF NOT EXISTS idx_weighted_votes_active_round
  ON public.weighted_votes(track_id, voting_round_id, vote_type)
  WHERE revoked_at IS NULL;

-- Raw votes contain anti-fraud metadata and must never be publicly readable.
DROP POLICY IF EXISTS "Anyone can view weighted votes" ON public.weighted_votes;
DROP POLICY IF EXISTS "Authenticated users can vote" ON public.weighted_votes;
DROP POLICY IF EXISTS "Users can delete own vote" ON public.weighted_votes;
DROP POLICY IF EXISTS "Users can update own vote" ON public.weighted_votes;
REVOKE ALL ON TABLE public.weighted_votes FROM anon, authenticated;

-- Uploaded tracks may enter community voting after moderation, and rejected
-- distribution requests must remain representable.
CREATE OR REPLACE FUNCTION public.check_distribution_requires_moderation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.source_type = 'uploaded'
     AND NEW.moderation_status IS DISTINCT FROM 'approved'
     AND NEW.distribution_status IN ('pending_moderation', 'pending_master', 'approved', 'processing', 'completed')
  THEN
    RAISE EXCEPTION 'Загруженный трек должен пройти модерацию перед продолжением дистрибуции';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_track_voting_totals(
  p_track_id uuid,
  p_round_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_likes numeric;
  v_dislikes numeric;
  v_like_count integer;
  v_dislike_count integer;
BEGIN
  SELECT
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'like' AND revoked_at IS NULL), 0),
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'dislike' AND revoked_at IS NULL), 0),
    COUNT(*) FILTER (WHERE vote_type = 'like' AND revoked_at IS NULL)::integer,
    COUNT(*) FILTER (WHERE vote_type = 'dislike' AND revoked_at IS NULL)::integer
  INTO v_likes, v_dislikes, v_like_count, v_dislike_count
  FROM public.weighted_votes
  WHERE track_id = p_track_id AND voting_round_id = p_round_id;

  UPDATE public.tracks
  SET weighted_likes_sum = v_likes,
      weighted_dislikes_sum = v_dislikes,
      voting_likes_count = v_like_count,
      voting_dislikes_count = v_dislike_count
  WHERE id = p_track_id AND voting_round_id = p_round_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_refresh_track_voting_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM public.refresh_track_voting_totals(OLD.track_id, OLD.voting_round_id);
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    IF TG_OP <> 'UPDATE'
       OR NEW.track_id IS DISTINCT FROM OLD.track_id
       OR NEW.voting_round_id IS DISTINCT FROM OLD.voting_round_id
       OR NEW.vote_type IS DISTINCT FROM OLD.vote_type
       OR NEW.final_weight IS DISTINCT FROM OLD.final_weight
       OR NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
    THEN
      PERFORM public.refresh_track_voting_totals(NEW.track_id, NEW.voting_round_id);
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_track_voting_totals ON public.weighted_votes;
CREATE TRIGGER trg_refresh_track_voting_totals
AFTER INSERT OR UPDATE OR DELETE ON public.weighted_votes
FOR EACH ROW EXECUTE FUNCTION public.trg_refresh_track_voting_totals();

CREATE OR REPLACE FUNCTION public.aggregate_votes_to_tracks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated integer;
BEGIN
  WITH totals AS (
    SELECT
      t.id,
      COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.vote_type = 'like' AND wv.revoked_at IS NULL), 0) likes_sum,
      COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.vote_type = 'dislike' AND wv.revoked_at IS NULL), 0) dislikes_sum,
      COUNT(wv.id) FILTER (WHERE wv.vote_type = 'like' AND wv.revoked_at IS NULL)::integer likes_count,
      COUNT(wv.id) FILTER (WHERE wv.vote_type = 'dislike' AND wv.revoked_at IS NULL)::integer dislikes_count
    FROM public.tracks t
    LEFT JOIN public.weighted_votes wv
      ON wv.track_id = t.id AND wv.voting_round_id = t.voting_round_id
    WHERE t.voting_round_id IS NOT NULL
    GROUP BY t.id
  )
  UPDATE public.tracks t
  SET weighted_likes_sum = totals.likes_sum,
      weighted_dislikes_sum = totals.dislikes_sum,
      voting_likes_count = totals.likes_count,
      voting_dislikes_count = totals.dislikes_count
  FROM totals
  WHERE t.id = totals.id
    AND (t.weighted_likes_sum, t.weighted_dislikes_sum, t.voting_likes_count, t.voting_dislikes_count)
      IS DISTINCT FROM (totals.likes_sum, totals.dislikes_sum, totals.likes_count, totals.dislikes_count);

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;

CREATE OR REPLACE FUNCTION public.assess_vote_fraud(
  p_user_id uuid,
  p_track_id uuid,
  p_fingerprint text DEFAULT NULL,
  p_ip inet DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_multiplier numeric := 1.0;
  v_track record;
  v_account_age_hours numeric;
  v_min_age_hours integer;
  v_ip_votes integer;
  v_velocity integer;
  v_same_author integer;
BEGIN
  SELECT id, user_id, voting_round_id INTO v_track
  FROM public.tracks WHERE id = p_track_id;

  IF v_track.user_id = p_user_id THEN RETURN 0; END IF;

  SELECT COALESCE(value::integer, 24) INTO v_min_age_hours
  FROM public.settings WHERE key = 'voting_min_account_age_hours';
  SELECT EXTRACT(epoch FROM (now() - created_at)) / 3600 INTO v_account_age_hours
  FROM auth.users WHERE id = p_user_id;
  IF COALESCE(v_account_age_hours, 0) < COALESCE(v_min_age_hours, 24) THEN
    v_multiplier := v_multiplier * 0.3;
  END IF;

  IF p_fingerprint IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.weighted_votes
    WHERE track_id = p_track_id
      AND voting_round_id = v_track.voting_round_id
      AND fingerprint_hash = p_fingerprint
      AND user_id <> p_user_id
      AND revoked_at IS NULL
  ) THEN
    RETURN 0;
  END IF;

  IF p_ip IS NOT NULL THEN
    SELECT COUNT(*) INTO v_ip_votes
    FROM public.weighted_votes
    WHERE track_id = p_track_id
      AND voting_round_id = v_track.voting_round_id
      AND ip_address = p_ip
      AND revoked_at IS NULL;
    IF v_ip_votes >= 3 THEN v_multiplier := v_multiplier * 0.1; END IF;
  END IF;

  SELECT COUNT(*) INTO v_velocity
  FROM public.weighted_votes
  WHERE user_id = p_user_id AND created_at > now() - interval '5 minutes';
  IF v_velocity >= 10 THEN v_multiplier := v_multiplier * 0.2; END IF;

  SELECT COUNT(*) INTO v_same_author
  FROM public.weighted_votes wv
  JOIN public.tracks t ON t.id = wv.track_id
  WHERE wv.user_id = p_user_id
    AND t.user_id = v_track.user_id
    AND wv.revoked_at IS NULL;
  IF v_same_author >= 5 THEN v_multiplier := v_multiplier * 0.3; END IF;

  IF EXISTS (
    SELECT 1 FROM public.referrals r
    WHERE ((r.referrer_id = p_user_id AND r.referred_id = v_track.user_id)
       OR (r.referrer_id = v_track.user_id AND r.referred_id = p_user_id))
      AND r.status = 'activated'
  ) THEN
    v_multiplier := v_multiplier * 0.5;
  END IF;

  RETURN GREATEST(0, LEAST(1, v_multiplier));
END;
$$;

CREATE OR REPLACE FUNCTION public.cast_weighted_vote(
  p_track_id uuid,
  p_vote_type text,
  p_fingerprint text DEFAULT NULL,
  p_context jsonb DEFAULT NULL,
  p_ip inet DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_track record;
  v_existing record;
  v_vote_id uuid;
  v_raw_weight numeric;
  v_fraud numeric;
  v_combo integer := 0;
  v_combo_bonus numeric := 0;
  v_final_weight numeric;
  v_fingerprint_hash text;
  v_hour_limit integer;
  v_recent_votes integer;
  v_xp integer := 0;
  v_is_new boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  IF p_vote_type NOT IN ('like', 'dislike') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid vote type');
  END IF;
  IF p_fingerprint IS NULL OR length(trim(p_fingerprint)) < 16 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Device fingerprint required');
  END IF;

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Track not found'); END IF;
  IF v_track.moderation_status <> 'voting'
     OR v_track.voting_type <> 'public'
     OR v_track.voting_round_id IS NULL
     OR v_track.voting_ends_at IS NULL
     OR v_track.voting_ends_at <= now()
  THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track is not in voting');
  END IF;
  IF v_track.user_id = v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'self_vote_blocked');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_user_id::text || p_track_id::text || v_track.voting_round_id::text, 0));
  v_fingerprint_hash := encode(digest(trim(p_fingerprint), 'sha256'), 'hex');

  SELECT * INTO v_existing
  FROM public.weighted_votes
  WHERE track_id = p_track_id
    AND user_id = v_user_id
    AND voting_round_id = v_track.voting_round_id
  FOR UPDATE;

  IF FOUND AND v_existing.revoked_at IS NULL AND v_existing.vote_type = p_vote_type THEN
    RETURN jsonb_build_object('success', true, 'unchanged', true, 'vote_id', v_existing.id, 'final_weight', v_existing.final_weight);
  END IF;

  IF NOT FOUND THEN
    SELECT COALESCE(value::integer, 20) INTO v_hour_limit
    FROM public.settings WHERE key = 'voting_rate_limit_per_hour';
    SELECT COUNT(*) INTO v_recent_votes
    FROM public.weighted_votes
    WHERE user_id = v_user_id AND created_at > now() - interval '1 hour';
    IF v_recent_votes >= COALESCE(v_hour_limit, 20) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Voting rate limit exceeded');
    END IF;
    v_is_new := true;
  END IF;

  v_raw_weight := LEAST(5, GREATEST(0, COALESCE(public.get_user_vote_weight(v_user_id), 1)));
  v_fraud := public.assess_vote_fraud(v_user_id, p_track_id, v_fingerprint_hash, p_ip);
  SELECT COALESCE(current_combo, 0) INTO v_combo FROM public.voter_profiles WHERE user_id = v_user_id;
  v_combo_bonus := CASE WHEN v_combo >= 21 THEN 0.5 WHEN v_combo >= 11 THEN 0.3 WHEN v_combo >= 6 THEN 0.2 WHEN v_combo >= 3 THEN 0.1 ELSE 0 END;
  v_final_weight := LEAST(5, v_raw_weight * v_fraud * (1 + v_combo_bonus));

  IF v_is_new THEN
    INSERT INTO public.weighted_votes(
      track_id, user_id, voting_round_id, vote_type, raw_weight,
      fraud_multiplier, combo_bonus, final_weight, fingerprint_hash,
      ip_address, context, revoked_at, updated_at
    ) VALUES (
      p_track_id, v_user_id, v_track.voting_round_id, p_vote_type, v_raw_weight,
      v_fraud, v_combo_bonus, v_final_weight, v_fingerprint_hash,
      p_ip, p_context, NULL, now()
    ) RETURNING id INTO v_vote_id;

    INSERT INTO public.voter_profiles(user_id, votes_cast_total, votes_cast_30d, last_vote_at, daily_votes_today, daily_votes_date, current_combo, best_combo, updated_at)
    VALUES (v_user_id, 1, 1, now(), 1, CURRENT_DATE, 1, 1, now())
    ON CONFLICT (user_id) DO UPDATE SET
      votes_cast_total = public.voter_profiles.votes_cast_total + 1,
      votes_cast_30d = public.voter_profiles.votes_cast_30d + 1,
      last_vote_at = now(),
      daily_votes_today = CASE WHEN public.voter_profiles.daily_votes_date = CURRENT_DATE THEN public.voter_profiles.daily_votes_today + 1 ELSE 1 END,
      daily_votes_date = CURRENT_DATE,
      current_combo = public.voter_profiles.current_combo + 1,
      best_combo = GREATEST(public.voter_profiles.best_combo, public.voter_profiles.current_combo + 1),
      updated_at = now();

    SELECT public.fn_add_xp(v_user_id, COALESCE((SELECT value::integer FROM public.settings WHERE key = 'xp_for_vote'), 2), 'social', false)
    INTO v_xp;
  ELSE
    UPDATE public.weighted_votes SET
      vote_type = p_vote_type,
      raw_weight = v_raw_weight,
      fraud_multiplier = v_fraud,
      combo_bonus = v_combo_bonus,
      final_weight = v_final_weight,
      fingerprint_hash = v_fingerprint_hash,
      ip_address = p_ip,
      context = p_context,
      revoked_at = NULL,
      updated_at = now()
    WHERE id = v_existing.id
    RETURNING id INTO v_vote_id;
  END IF;

  INSERT INTO public.vote_audit_log(vote_id, action, details)
  VALUES (
    v_vote_id,
    CASE WHEN v_is_new THEN 'cast' ELSE 'change' END,
    jsonb_build_object('user_id', v_user_id, 'round_id', v_track.voting_round_id, 'vote_type', p_vote_type, 'final_weight', v_final_weight)
  );

  RETURN jsonb_build_object(
    'success', true,
    'vote_id', v_vote_id,
    'final_weight', v_final_weight,
    'combo_length', v_combo + CASE WHEN v_is_new THEN 1 ELSE 0 END,
    'xp_earned', v_xp
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_vote(p_track_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_vote_id uuid;
  v_round_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT voting_round_id INTO v_round_id FROM public.tracks WHERE id = p_track_id;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_user_id::text || p_track_id::text || COALESCE(v_round_id::text, ''), 0));

  UPDATE public.weighted_votes
  SET revoked_at = now(), final_weight = 0, updated_at = now()
  WHERE track_id = p_track_id
    AND user_id = v_user_id
    AND voting_round_id = v_round_id
    AND revoked_at IS NULL
  RETURNING id INTO v_vote_id;

  IF v_vote_id IS NOT NULL THEN
    INSERT INTO public.vote_audit_log(vote_id, action, details)
    VALUES (v_vote_id, 'revoke', jsonb_build_object('user_id', v_user_id, 'round_id', v_round_id));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_weighted_vote(p_track_id uuid)
RETURNS TABLE(id uuid, vote_type text, final_weight numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT wv.id, wv.vote_type, wv.final_weight
  FROM public.weighted_votes wv
  JOIN public.tracks t ON t.id = wv.track_id AND t.voting_round_id = wv.voting_round_id
  WHERE wv.track_id = p_track_id
    AND wv.user_id = auth.uid()
    AND wv.revoked_at IS NULL
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_voting_live_stats(p_track_ids uuid[])
RETURNS TABLE(
  track_id uuid,
  weighted_likes numeric,
  weighted_dislikes numeric,
  total_voters bigint,
  like_count bigint,
  dislike_count bigint,
  approval_rate numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    requested.track_id,
    COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.vote_type = 'like' AND wv.revoked_at IS NULL), 0),
    COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.vote_type = 'dislike' AND wv.revoked_at IS NULL), 0),
    COUNT(wv.id) FILTER (WHERE wv.revoked_at IS NULL),
    COUNT(wv.id) FILTER (WHERE wv.vote_type = 'like' AND wv.revoked_at IS NULL),
    COUNT(wv.id) FILTER (WHERE wv.vote_type = 'dislike' AND wv.revoked_at IS NULL),
    CASE WHEN COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.revoked_at IS NULL), 0) > 0
      THEN COALESCE(SUM(wv.final_weight) FILTER (WHERE wv.vote_type = 'like' AND wv.revoked_at IS NULL), 0)
           / SUM(wv.final_weight) FILTER (WHERE wv.revoked_at IS NULL)
      ELSE 0 END
  FROM unnest(p_track_ids) AS requested(track_id)
  LEFT JOIN public.tracks t ON t.id = requested.track_id
  LEFT JOIN public.weighted_votes wv
    ON wv.track_id = t.id AND wv.voting_round_id = t.voting_round_id
  GROUP BY requested.track_id;
$$;

-- Forum topic creation remains callable for compatibility, but is now
-- authenticated, manager-only, idempotent, and cannot impersonate a moderator.
CREATE OR REPLACE FUNCTION public.create_voting_forum_topic(p_track_id uuid, p_moderator_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_track record;
  v_topic_id uuid;
  v_category_id uuid;
  v_username text;
  v_title text;
  v_slug text;
  v_content text;
BEGIN
  IF v_caller IS NULL
     OR p_moderator_id IS DISTINCT FROM v_caller
     OR NOT (public.is_admin(v_caller) OR public.has_permission(v_caller, 'moderation'))
  THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Track not found'; END IF;
  IF v_track.moderation_status <> 'voting' OR v_track.voting_type <> 'public' THEN
    RAISE EXCEPTION 'Track is not in public voting';
  END IF;

  SELECT id INTO v_topic_id FROM public.forum_topics WHERE track_id = p_track_id ORDER BY created_at DESC LIMIT 1;
  IF v_topic_id IS NOT NULL THEN
    UPDATE public.forum_topics SET is_locked = false, is_pinned = true, is_hidden = false WHERE id = v_topic_id;
    UPDATE public.tracks SET forum_topic_id = v_topic_id WHERE id = p_track_id;
    RETURN v_topic_id;
  END IF;

  SELECT value::uuid INTO v_category_id FROM public.settings WHERE key = 'forum_voting_category_id';
  IF v_category_id IS NULL THEN RAISE EXCEPTION 'Voting forum category is not configured'; END IF;
  SELECT COALESCE(username, 'Автор') INTO v_username FROM public.profiles WHERE user_id = v_track.user_id;

  v_title := '🗳️ Голосование на дистрибуцию: ' || v_track.title;
  v_slug := 'voting-' || p_track_id::text || '-' || replace(v_track.voting_round_id::text, '-', '');
  v_content := '## 🎵 ' || v_track.title || E'\n\n'
    || '**Исполнитель:** ' || COALESCE(v_username, 'Автор') || E'\n'
    || '**Голосование до:** ' || to_char(v_track.voting_ends_at AT TIME ZONE 'Europe/Moscow', 'DD.MM.YYYY HH24:MI') || E' (МСК)\n\n'
    || 'Прослушайте трек и проголосуйте в виджете ниже.';

  INSERT INTO public.forum_topics(category_id, user_id, title, slug, content, excerpt, track_id, is_pinned, is_hidden)
  VALUES (v_category_id, v_caller, v_title, v_slug, v_content, 'Голосование сообщества за трек «' || v_track.title || '».', p_track_id, true, false)
  RETURNING id INTO v_topic_id;

  UPDATE public.tracks SET forum_topic_id = v_topic_id WHERE id = p_track_id;
  RETURN v_topic_id;
END;
$$;

-- PostgreSQL cannot change a function return type through CREATE OR REPLACE.
-- Older production installations still have this signature returning boolean.
DROP FUNCTION IF EXISTS public.send_track_to_voting(uuid, integer, text);

CREATE FUNCTION public.send_track_to_voting(
  p_track_id uuid,
  p_duration_days integer DEFAULT NULL,
  p_voting_type text DEFAULT 'public'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_track record;
  v_duration integer;
  v_round_id uuid := gen_random_uuid();
  v_topic_id uuid;
BEGIN
  IF v_caller IS NULL OR NOT (public.is_admin(v_caller) OR public.has_permission(v_caller, 'moderation')) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  IF p_voting_type IS DISTINCT FROM 'public' THEN
    RAISE EXCEPTION 'Поддерживается только публичное голосование сообщества';
  END IF;

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Track not found'; END IF;
  IF v_track.moderation_status = 'voting' AND v_track.voting_ends_at > now() THEN
    RAISE EXCEPTION 'Трек уже находится в активном голосовании';
  END IF;

  v_duration := COALESCE(p_duration_days, (SELECT value::integer FROM public.settings WHERE key = 'voting_duration_days'), 7);
  IF v_duration < 1 OR v_duration > 30 THEN
    RAISE EXCEPTION 'Длительность голосования должна быть от 1 до 30 дней';
  END IF;

  UPDATE public.tracks SET
    moderation_status = 'voting',
    distribution_status = CASE WHEN distribution_status = 'pending_moderation' THEN 'voting' ELSE distribution_status END,
    voting_type = 'public',
    voting_round_id = v_round_id,
    voting_started_at = now(),
    voting_ends_at = now() + make_interval(days => v_duration),
    voting_result = 'pending',
    voting_likes_count = 0,
    voting_dislikes_count = 0,
    weighted_likes_sum = 0,
    weighted_dislikes_sum = 0,
    is_public = true
  WHERE id = p_track_id;

  v_topic_id := public.create_voting_forum_topic(p_track_id, v_caller);

  INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id)
  VALUES (v_track.user_id, 'voting_started', '🗳️ Трек на голосовании сообщества',
          'Ваш трек отправлен на голосование на ' || v_duration || ' дн.', 'track', p_track_id);

  RETURN jsonb_build_object(
    'success', true,
    'voting_type', 'public',
    'voting_round_id', v_round_id,
    'voting_ends_at', now() + make_interval(days => v_duration),
    'duration_days', v_duration,
    'forum_topic_id', v_topic_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_track_voting_core(p_track_id uuid, p_manual_result text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track record;
  v_min_votes integer;
  v_approval_ratio numeric;
  v_total_voters integer;
  v_likes numeric;
  v_dislikes numeric;
  v_ratio numeric;
  v_result text;
  v_distribution_result text;
  v_moderation_result text;
  v_message text;
BEGIN
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Track not found'); END IF;
  IF v_track.moderation_status <> 'voting' OR v_track.voting_result IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Voting already resolved');
  END IF;
  IF p_manual_result IS NULL AND v_track.voting_ends_at > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Voting is still active');
  END IF;
  IF p_manual_result IS NOT NULL AND p_manual_result NOT IN ('approved', 'rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid manual result');
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE revoked_at IS NULL)::integer,
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'like' AND revoked_at IS NULL), 0),
    COALESCE(SUM(final_weight) FILTER (WHERE vote_type = 'dislike' AND revoked_at IS NULL), 0)
  INTO v_total_voters, v_likes, v_dislikes
  FROM public.weighted_votes
  WHERE track_id = p_track_id AND voting_round_id = v_track.voting_round_id;

  SELECT COALESCE(value::integer, 10) INTO v_min_votes FROM public.settings WHERE key = 'voting_min_votes';
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio FROM public.settings WHERE key = 'voting_approval_ratio';
  v_ratio := CASE WHEN v_likes + v_dislikes > 0 THEN v_likes / (v_likes + v_dislikes) ELSE 0 END;

  IF p_manual_result IS NOT NULL THEN
    v_result := p_manual_result;
  ELSIF v_total_voters >= v_min_votes AND v_ratio >= v_approval_ratio THEN
    v_result := 'approved';
  ELSE
    v_result := 'rejected';
  END IF;

  v_distribution_result := CASE
    WHEN v_track.distribution_status = 'voting' AND v_result = 'approved' THEN 'pending_master'
    WHEN v_track.distribution_status = 'voting' AND v_result = 'rejected' THEN 'rejected'
    ELSE v_track.distribution_status
  END;
  v_moderation_result := CASE
    WHEN v_track.distribution_status = 'voting' AND v_result = 'approved' THEN 'approved'
    WHEN v_result = 'approved' THEN 'pending'
    ELSE 'rejected'
  END;

  UPDATE public.tracks SET
    moderation_status = v_moderation_result,
    distribution_status = v_distribution_result,
    voting_result = CASE WHEN p_manual_result IS NULL AND v_result = 'approved' THEN 'voting_approved'
                         WHEN p_manual_result IS NULL THEN 'rejected'
                         ELSE 'manual_override_' || v_result END,
    is_public = false
  WHERE id = p_track_id;

  UPDATE public.voter_profiles vp
  SET correct_predictions = vp.correct_predictions + 1,
      accuracy_rate = LEAST(1, (vp.correct_predictions + 1)::numeric / GREATEST(vp.votes_cast_total, 1)),
      updated_at = now()
  FROM public.weighted_votes wv
  WHERE wv.track_id = p_track_id
    AND wv.voting_round_id = v_track.voting_round_id
    AND wv.revoked_at IS NULL
    AND wv.user_id = vp.user_id
    AND ((v_result = 'approved' AND wv.vote_type = 'like') OR (v_result = 'rejected' AND wv.vote_type = 'dislike'));

  v_message := CASE WHEN v_result = 'approved'
    THEN '✅ Голосование завершено. Трек одобрен (' || round(v_ratio * 100) || '% положительных голосов).'
    ELSE '❌ Голосование завершено. Трек не прошёл отбор (' || round(v_ratio * 100) || '% положительных голосов).'
  END;

  IF v_track.forum_topic_id IS NOT NULL THEN
    INSERT INTO public.forum_posts(topic_id, user_id, content)
    VALUES (v_track.forum_topic_id, '00000000-0000-0000-0000-000000000000', v_message);
    UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
  END IF;

  IF COALESCE((SELECT value FROM public.settings WHERE key = 'voting_notify_artist'), 'true') = 'true' THEN
    INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id)
    VALUES (v_track.user_id, 'voting_result',
            CASE WHEN v_result = 'approved' THEN '🎉 Голосование пройдено!' ELSE 'Голосование завершено' END,
            v_message, 'track', p_track_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'method', CASE WHEN p_manual_result IS NULL THEN 'automatic' ELSE 'manual_override' END,
    'total_votes', v_total_voters,
    'like_ratio', v_ratio,
    'min_votes_required', v_min_votes,
    'approval_ratio_required', v_approval_ratio,
    'new_moderation_status', v_moderation_result,
    'new_distribution_status', v_distribution_result
  );
END;
$$;

-- Legacy production versions returned void for this signature.
DROP FUNCTION IF EXISTS public.resolve_track_voting(uuid, text);

CREATE FUNCTION public.resolve_track_voting(p_track_id uuid, p_manual_result text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  RETURN public.resolve_track_voting_core(p_track_id, p_manual_result);
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_expired_votings()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track_id uuid;
  v_result jsonb;
  v_processed integer := 0;
BEGIN
  FOR v_track_id IN
    SELECT id FROM public.tracks
    WHERE moderation_status = 'voting'
      AND voting_result = 'pending'
      AND voting_ends_at <= now()
    ORDER BY voting_ends_at
  LOOP
    v_result := public.resolve_track_voting_core(v_track_id, NULL);
    IF COALESCE((v_result->>'success')::boolean, false) THEN
      v_processed := v_processed + 1;
    END IF;
  END LOOP;
  RETURN v_processed;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_annul_vote(p_vote_id uuid, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Forbidden'; END IF;
  UPDATE public.weighted_votes
  SET revoked_at = now(), final_weight = 0, updated_at = now()
  WHERE id = p_vote_id AND revoked_at IS NULL
  RETURNING user_id INTO v_user_id;
  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.vote_audit_log(vote_id, action, details)
    VALUES (p_vote_id, 'revoke', jsonb_build_object('admin_annul', true, 'reason', p_reason, 'user_id', v_user_id));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_flagged_votes(p_page integer DEFAULT 1, p_per_page integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows jsonb;
  v_total integer;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Forbidden'; END IF;
  SELECT COUNT(*) INTO v_total FROM public.weighted_votes WHERE fraud_multiplier < 0.5 AND revoked_at IS NULL;
  SELECT jsonb_agg(row_to_json(v)) INTO v_rows FROM (
    SELECT id, track_id, user_id, vote_type, fraud_multiplier, created_at
    FROM public.weighted_votes
    WHERE fraud_multiplier < 0.5 AND revoked_at IS NULL
    ORDER BY created_at DESC
    LIMIT p_per_page OFFSET GREATEST(0, (p_page - 1) * p_per_page)
  ) v;
  RETURN jsonb_build_object('votes', COALESCE(v_rows, '[]'::jsonb), 'total', v_total);
END;
$$;

-- Explicit execution surface. Internal maintenance functions are callable only
-- by the database owner/service role, never through anonymous PostgREST.
REVOKE ALL ON FUNCTION public.cast_weighted_vote(uuid, text, text, jsonb, inet) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cast_weighted_vote(uuid, text, text, jsonb, inet) TO authenticated;
REVOKE ALL ON FUNCTION public.revoke_vote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_vote(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_weighted_vote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_weighted_vote(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_voting_live_stats(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_voting_live_stats(uuid[]) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.send_track_to_voting(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_track_to_voting(uuid, integer, text) TO authenticated;
REVOKE ALL ON FUNCTION public.create_voting_forum_topic(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_voting_forum_topic(uuid, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_track_voting(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_track_voting(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_track_voting_core(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_expired_votings() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.aggregate_votes_to_tracks() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.assess_vote_fraud(uuid, uuid, text, inet) FROM PUBLIC, anon, authenticated;

SELECT public.aggregate_votes_to_tracks();

COMMIT;
