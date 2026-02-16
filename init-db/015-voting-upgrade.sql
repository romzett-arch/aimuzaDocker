-- ═══════════════════════════════════════════════════════════
-- 015: Public Voting Upgrade
-- Anti-fraud, comment on votes, new settings, recent voters
-- ═══════════════════════════════════════════════════════════

-- ── Add comment column to track_votes ────────────────────
ALTER TABLE public.track_votes ADD COLUMN IF NOT EXISTS comment TEXT;

-- ── New voting settings ──────────────────────────────────
INSERT INTO public.settings (key, value, description) VALUES
  ('voting_min_account_age_hours', '24', 'Минимальный возраст аккаунта для голосования (часы)'),
  ('voting_rate_limit_per_hour', '20', 'Максимум голосов в час от одного пользователя')
ON CONFLICT (key) DO NOTHING;

-- ── Anti-fraud: BEFORE INSERT trigger on track_votes ─────

CREATE OR REPLACE FUNCTION public.check_voting_eligibility()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_created_at TIMESTAMP WITH TIME ZONE;
  v_min_age_hours INTEGER;
  v_rate_limit INTEGER;
  v_recent_votes INTEGER;
BEGIN
  -- 1. Check account age
  SELECT created_at INTO v_account_created_at
  FROM auth.users WHERE id = NEW.user_id;

  SELECT COALESCE((SELECT value::integer FROM public.settings WHERE key = 'voting_min_account_age_hours'), 24)
  INTO v_min_age_hours;

  IF v_account_created_at IS NOT NULL AND
     v_account_created_at > now() - (v_min_age_hours || ' hours')::interval THEN
    RAISE EXCEPTION 'Account must be at least % hours old to vote', v_min_age_hours;
  END IF;

  -- 2. Check rate limit
  SELECT COALESCE((SELECT value::integer FROM public.settings WHERE key = 'voting_rate_limit_per_hour'), 20)
  INTO v_rate_limit;

  SELECT COUNT(*) INTO v_recent_votes
  FROM public.track_votes
  WHERE user_id = NEW.user_id AND created_at > now() - interval '1 hour';

  IF v_recent_votes >= v_rate_limit THEN
    RAISE EXCEPTION 'Vote rate limit exceeded: max % per hour', v_rate_limit;
  END IF;

  -- 3. Prevent self-voting
  IF EXISTS (SELECT 1 FROM public.tracks WHERE id = NEW.track_id AND user_id = NEW.user_id) THEN
    RAISE EXCEPTION 'Cannot vote on your own track';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_voting_eligibility ON public.track_votes;
CREATE TRIGGER trigger_check_voting_eligibility
  BEFORE INSERT ON public.track_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.check_voting_eligibility();

-- ── Function: get recent voters for a track ──────────────

CREATE OR REPLACE FUNCTION public.get_recent_voters(p_track_id UUID, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(user_id UUID, username TEXT, avatar_url TEXT, vote_type TEXT, voted_at TIMESTAMP WITH TIME ZONE)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    tv.user_id,
    p.username,
    p.avatar_url,
    tv.vote_type,
    tv.created_at AS voted_at
  FROM public.track_votes tv
  LEFT JOIN public.profiles p ON p.user_id = tv.user_id
  WHERE tv.track_id = p_track_id
  ORDER BY tv.created_at DESC
  LIMIT p_limit;
END;
$$;

-- ── Index for faster voter queries ───────────────────────
CREATE INDEX IF NOT EXISTS idx_track_votes_recent
  ON public.track_votes(track_id, created_at DESC);
