-- ═══════════════════════════════════════════════════════════
-- 014: Professional Moderation Pipeline
-- Adds risk scoring, priority queue, SLA deadlines,
-- moderator locking, and syncs resolve_track_voting RPC
-- ═══════════════════════════════════════════════════════════

-- ── New columns for moderation pipeline ──────────────────

-- Risk score from automated checks (0-100)
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_risk_score INTEGER DEFAULT NULL;

-- Auto-check results as structured JSON
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_auto_checks JSONB DEFAULT '{}';

-- Priority for queue ordering
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_priority TEXT DEFAULT 'normal';

-- SLA deadline — when moderation decision is expected by
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_sla_deadline TIMESTAMP WITH TIME ZONE;

-- Lock track to a specific moderator (prevents double moderation)
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_locked_by UUID REFERENCES auth.users(id);
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_locked_at TIMESTAMP WITH TIME ZONE;

-- Index for priority queue ordering
CREATE INDEX IF NOT EXISTS idx_tracks_moderation_priority 
  ON public.tracks(moderation_priority, moderation_sla_deadline) 
  WHERE moderation_status IN ('pending', 'none');

-- Index for locked tracks cleanup
CREATE INDEX IF NOT EXISTS idx_tracks_moderation_locked 
  ON public.tracks(moderation_locked_by) 
  WHERE moderation_locked_by IS NOT NULL;

-- ── Priority constraint ──────────────────────────────────

DO $$ BEGIN
  ALTER TABLE public.tracks ADD CONSTRAINT chk_moderation_priority
    CHECK (moderation_priority IN ('low', 'normal', 'high', 'urgent'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── Function: Calculate risk score and auto-route ─────────

CREATE OR REPLACE FUNCTION public.calculate_moderation_risk_score(p_track_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track RECORD;
  v_score INTEGER := 0;
  v_priority TEXT;
  v_sla_hours INTEGER;
BEGIN
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  IF v_track IS NULL THEN RETURN NULL; END IF;

  -- Base score: 30 (medium) for uploaded tracks
  v_score := 30;

  -- Plagiarism check results
  IF v_track.plagiarism_check_status = 'blocked' THEN
    v_score := v_score + 60; -- Critical: nearly guaranteed plagiarism
  ELSIF v_track.plagiarism_check_status = 'flagged' THEN
    v_score := v_score + 30; -- High: potential matches found
  ELSIF v_track.plagiarism_check_status = 'clean' THEN
    v_score := v_score - 20; -- Low risk: passed check
  END IF;

  -- Copyright check results
  IF v_track.copyright_check_status = 'blocked' THEN
    v_score := v_score + 40;
  ELSIF v_track.copyright_check_status = 'flagged' THEN
    v_score := v_score + 20;
  ELSIF v_track.copyright_check_status = 'clean' THEN
    v_score := v_score - 10;
  END IF;

  -- Legal declarations reduce risk
  IF v_track.is_original_work = true THEN
    v_score := v_score - 10;
  END IF;

  -- Clamp to 0-100
  v_score := GREATEST(0, LEAST(100, v_score));

  -- Determine priority based on score
  IF v_score >= 86 THEN
    v_priority := 'urgent';
    v_sla_hours := 4;      -- 4 hours for critical
  ELSIF v_score >= 61 THEN
    v_priority := 'high';
    v_sla_hours := 24;     -- 24 hours for high
  ELSIF v_score >= 21 THEN
    v_priority := 'normal';
    v_sla_hours := 72;     -- 3 days for normal
  ELSE
    v_priority := 'low';
    v_sla_hours := 168;    -- 7 days for low
  END IF;

  -- Update the track
  UPDATE public.tracks SET
    moderation_risk_score = v_score,
    moderation_priority = v_priority,
    moderation_sla_deadline = now() + (v_sla_hours || ' hours')::interval,
    moderation_auto_checks = jsonb_build_object(
      'plagiarism_status', v_track.plagiarism_check_status,
      'copyright_status', v_track.copyright_check_status,
      'is_original_work', v_track.is_original_work,
      'calculated_at', now()
    )
  WHERE id = p_track_id;

  RETURN v_score;
END;
$$;

-- ── Function: Lock track for moderator ────────────────────

CREATE OR REPLACE FUNCTION public.lock_track_for_moderation(
  p_track_id UUID,
  p_moderator_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Try to lock: only succeeds if not already locked or lock expired (>30 min)
  UPDATE public.tracks SET
    moderation_locked_by = p_moderator_id,
    moderation_locked_at = now()
  WHERE id = p_track_id
    AND (
      moderation_locked_by IS NULL
      OR moderation_locked_by = p_moderator_id
      OR moderation_locked_at < now() - interval '30 minutes'
    );

  RETURN FOUND;
END;
$$;

-- ── Function: Unlock track ────────────────────────────────

CREATE OR REPLACE FUNCTION public.unlock_track_moderation(
  p_track_id UUID,
  p_moderator_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.tracks SET
    moderation_locked_by = NULL,
    moderation_locked_at = NULL
  WHERE id = p_track_id
    AND (moderation_locked_by = p_moderator_id OR public.is_admin(p_moderator_id));
END;
$$;

-- ── Sync resolve_track_voting RPC with edge function logic ─

-- Drop old version
DROP FUNCTION IF EXISTS public.resolve_track_voting(uuid, text);

CREATE OR REPLACE FUNCTION public.resolve_track_voting(
  p_track_id UUID,
  p_manual_result TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_like_ratio NUMERIC;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_result TEXT;
  v_new_status TEXT;
  v_reason TEXT;
BEGIN
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('error', 'Track not found');
  END IF;

  -- Get voting settings
  SELECT COALESCE((SELECT value::integer FROM public.settings WHERE key = 'voting_min_votes'), 10) INTO v_min_votes;
  SELECT COALESCE((SELECT value::numeric FROM public.settings WHERE key = 'voting_approval_ratio'), 0.6) INTO v_approval_ratio;

  -- Manual override
  IF p_manual_result IS NOT NULL THEN
    IF p_manual_result = 'approved' THEN
      v_result := 'voting_approved';
      v_new_status := 'pending'; -- Back to moderation queue
      v_reason := 'Вручную одобрено модератором';
    ELSE
      v_result := 'rejected';
      v_new_status := 'rejected';
      v_reason := 'Вручную отклонено модератором';
    END IF;
  ELSE
    -- Automatic resolution based on votes
    v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);

    IF v_total_votes < v_min_votes THEN
      v_result := 'rejected';
      v_new_status := 'rejected';
      v_reason := format('Недостаточно голосов: %s из %s минимальных', v_total_votes, v_min_votes);
    ELSE
      v_like_ratio := COALESCE(v_track.voting_likes_count, 0)::numeric / v_total_votes;
      IF v_like_ratio >= v_approval_ratio THEN
        v_result := 'voting_approved';
        v_new_status := 'pending'; -- Back to moderation queue for final label decision
        v_reason := format('Голосование пройдено: %s%% положительных', round(v_like_ratio * 100));
      ELSE
        v_result := 'rejected';
        v_new_status := 'rejected';
        v_reason := format('Отклонено: %s%% положительных (нужно %s%%)', round(v_like_ratio * 100), round(v_approval_ratio * 100));
      END IF;
    END IF;
  END IF;

  -- Update track — CRITICAL: Do NOT auto-publish
  UPDATE public.tracks SET
    moderation_status = v_new_status,
    voting_result = v_result,
    is_public = false
  WHERE id = p_track_id;

  RETURN jsonb_build_object(
    'result', v_result,
    'new_status', v_new_status,
    'reason', v_reason,
    'total_votes', COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0),
    'likes', COALESCE(v_track.voting_likes_count, 0),
    'dislikes', COALESCE(v_track.voting_dislikes_count, 0)
  );
END;
$$;

-- ── Add internal voting resolution to radio cron ──────────
-- (Handled in radio/server.js — resolveExpiredVoting already runs every 60s)
-- Internal voting is resolved via resolve_internal_voting RPC

-- ── Trigger: auto-calculate risk score on moderation submit ─

CREATE OR REPLACE FUNCTION public.trigger_auto_risk_score()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only calculate for uploaded tracks entering moderation
  IF NEW.source_type = 'uploaded' 
    AND NEW.moderation_status IN ('pending', 'none')
    AND NEW.moderation_risk_score IS NULL 
  THEN
    PERFORM public.calculate_moderation_risk_score(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_calculate_risk_score ON public.tracks;
CREATE TRIGGER trigger_calculate_risk_score
  AFTER INSERT OR UPDATE OF moderation_status ON public.tracks
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_auto_risk_score();
