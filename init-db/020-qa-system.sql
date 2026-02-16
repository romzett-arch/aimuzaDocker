-- ============================================================
-- QA SYSTEM — Community-Driven Bug Reports & Tickets
-- Full migration: tables, functions, RLS, seeds
-- ============================================================

-- Enable trigram extension for deduplication
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 1. TABLES
-- ============================================================

-- Main QA Tickets
CREATE TABLE IF NOT EXISTS public.qa_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_number TEXT UNIQUE,
  reporter_id UUID NOT NULL,

  -- Classification
  category TEXT NOT NULL DEFAULT 'ui',
  severity TEXT NOT NULL DEFAULT 'minor',
  status TEXT NOT NULL DEFAULT 'new',

  -- Content
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  steps_to_reproduce TEXT,
  expected_behavior TEXT,
  actual_behavior TEXT,

  -- Environment
  page_url TEXT,
  user_agent TEXT,
  browser_info JSONB DEFAULT '{}'::jsonb,

  -- Media
  screenshots JSONB DEFAULT '[]'::jsonb,

  -- Deduplication
  duplicate_of UUID REFERENCES public.qa_tickets(id),

  -- Verification
  is_verified BOOLEAN DEFAULT false,
  verified_by UUID,
  verified_at TIMESTAMPTZ,
  verification_count INTEGER DEFAULT 0,

  -- Resolution
  assigned_to UUID,
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  resolution_notes TEXT,

  -- Rewards
  reward_xp INTEGER DEFAULT 0,
  reward_credits INTEGER DEFAULT 0,
  bounty_id UUID,

  -- Scoring
  upvotes INTEGER DEFAULT 0,
  priority_score NUMERIC DEFAULT 0,

  -- Meta
  tags TEXT[] DEFAULT '{}',
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- QA Comments (thread on tickets)
CREATE TABLE IF NOT EXISTS public.qa_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.qa_tickets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  message TEXT NOT NULL,
  is_staff BOOLEAN DEFAULT false,
  is_system BOOLEAN DEFAULT false,
  attachments JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- QA Votes (community confirmation)
CREATE TABLE IF NOT EXISTS public.qa_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.qa_tickets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  vote_type TEXT NOT NULL DEFAULT 'confirm',
  voter_weight NUMERIC DEFAULT 1.0,
  comment TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(ticket_id, user_id, vote_type)
);

-- QA Bounties
CREATE TABLE IF NOT EXISTS public.qa_bounties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  category TEXT,
  severity_min TEXT DEFAULT 'minor',
  reward_xp INTEGER DEFAULT 0,
  reward_credits INTEGER DEFAULT 0,
  max_claims INTEGER DEFAULT 10,
  claimed_count INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  expires_at TIMESTAMPTZ,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- QA Tester Stats (per-user)
CREATE TABLE IF NOT EXISTS public.qa_tester_stats (
  user_id UUID PRIMARY KEY,
  tier TEXT DEFAULT 'contributor',
  reports_total INTEGER DEFAULT 0,
  reports_confirmed INTEGER DEFAULT 0,
  reports_rejected INTEGER DEFAULT 0,
  reports_critical INTEGER DEFAULT 0,
  votes_cast INTEGER DEFAULT 0,
  accuracy_rate NUMERIC DEFAULT 0,
  xp_earned INTEGER DEFAULT 0,
  credits_earned INTEGER DEFAULT 0,
  streak_days INTEGER DEFAULT 0,
  best_streak INTEGER DEFAULT 0,
  last_report_at TIMESTAMPTZ,
  tier_updated_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- QA Config (key-value settings)
CREATE TABLE IF NOT EXISTS public.qa_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  label TEXT,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 2. INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_qa_tickets_reporter ON public.qa_tickets(reporter_id);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_status ON public.qa_tickets(status);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_category ON public.qa_tickets(category);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_severity ON public.qa_tickets(severity);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_created ON public.qa_tickets(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_priority ON public.qa_tickets(priority_score DESC);
CREATE INDEX IF NOT EXISTS idx_qa_tickets_title_trgm ON public.qa_tickets USING gin (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_qa_comments_ticket ON public.qa_comments(ticket_id);
CREATE INDEX IF NOT EXISTS idx_qa_votes_ticket ON public.qa_votes(ticket_id);
CREATE INDEX IF NOT EXISTS idx_qa_tester_stats_tier ON public.qa_tester_stats(tier);

-- ============================================================
-- 3. FUNCTIONS
-- ============================================================

-- Auto ticket number: QA-XXXXXX
CREATE OR REPLACE FUNCTION public.qa_generate_ticket_number()
RETURNS TRIGGER AS $$
DECLARE
  next_num INTEGER;
BEGIN
  SELECT COALESCE(MAX(CAST(SUBSTRING(ticket_number FROM 4) AS INTEGER)), 0) + 1
    INTO next_num
    FROM public.qa_tickets
    WHERE ticket_number LIKE 'QA-%';
  NEW.ticket_number := 'QA-' || LPAD(next_num::TEXT, 6, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_qa_ticket_number ON public.qa_tickets;
CREATE TRIGGER trg_qa_ticket_number
  BEFORE INSERT ON public.qa_tickets
  FOR EACH ROW
  WHEN (NEW.ticket_number IS NULL)
  EXECUTE FUNCTION public.qa_generate_ticket_number();

-- Updated_at trigger
CREATE OR REPLACE FUNCTION public.qa_update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_qa_tickets_updated ON public.qa_tickets;
CREATE TRIGGER trg_qa_tickets_updated
  BEFORE UPDATE ON public.qa_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.qa_update_timestamp();

-- Find similar tickets (deduplication)
CREATE OR REPLACE FUNCTION public.find_similar_qa_tickets(
  p_title TEXT,
  p_category TEXT DEFAULT NULL,
  p_threshold NUMERIC DEFAULT 0.3,
  p_limit INTEGER DEFAULT 5
)
RETURNS TABLE(
  id UUID,
  ticket_number TEXT,
  title TEXT,
  status TEXT,
  category TEXT,
  severity TEXT,
  similarity_score NUMERIC,
  upvotes INTEGER,
  created_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id,
    t.ticket_number,
    t.title,
    t.status,
    t.category,
    t.severity,
    ROUND(similarity(t.title, p_title)::NUMERIC, 3) AS similarity_score,
    t.upvotes,
    t.created_at
  FROM public.qa_tickets t
  WHERE similarity(t.title, p_title) > p_threshold
    AND t.status NOT IN ('closed', 'duplicate')
    AND (p_category IS NULL OR t.category = p_category)
  ORDER BY similarity(t.title, p_title) DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Vote on QA ticket
CREATE OR REPLACE FUNCTION public.vote_qa_ticket(
  p_ticket_id UUID,
  p_vote_type TEXT DEFAULT 'confirm'
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_voter_weight NUMERIC;
  v_ticket_reporter UUID;
  v_existing UUID;
  v_new_count INTEGER;
  v_threshold INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- Can't vote on own ticket
  SELECT reporter_id INTO v_ticket_reporter FROM public.qa_tickets WHERE id = p_ticket_id;
  IF v_ticket_reporter = v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot vote on own ticket');
  END IF;

  -- Check for existing vote
  SELECT id INTO v_existing FROM public.qa_votes
    WHERE ticket_id = p_ticket_id AND user_id = v_user_id AND vote_type = p_vote_type;
  IF v_existing IS NOT NULL THEN
    -- Remove vote
    DELETE FROM public.qa_votes WHERE id = v_existing;
    UPDATE public.qa_tickets
      SET upvotes = GREATEST(0, upvotes - 1),
          verification_count = CASE WHEN p_vote_type = 'confirm'
            THEN GREATEST(0, verification_count - 1) ELSE verification_count END
      WHERE id = p_ticket_id;
    RETURN jsonb_build_object('success', true, 'action', 'removed');
  END IF;

  -- Get voter weight from reputation tier
  SELECT COALESCE(vote_weight, 1.0) INTO v_voter_weight
    FROM public.forum_user_stats WHERE user_id = v_user_id;
  IF v_voter_weight IS NULL THEN v_voter_weight := 1.0; END IF;

  -- Insert vote
  INSERT INTO public.qa_votes (ticket_id, user_id, vote_type, voter_weight)
    VALUES (p_ticket_id, v_user_id, p_vote_type, v_voter_weight);

  -- Update ticket counts
  UPDATE public.qa_tickets
    SET upvotes = upvotes + 1,
        verification_count = CASE WHEN p_vote_type = 'confirm'
          THEN verification_count + 1 ELSE verification_count END
    WHERE id = p_ticket_id
    RETURNING verification_count INTO v_new_count;

  -- Auto-verify if threshold reached
  SELECT COALESCE((value->>'confirmation_threshold')::INTEGER, 3) INTO v_threshold
    FROM public.qa_config WHERE key = 'general';

  IF v_new_count >= v_threshold THEN
    UPDATE public.qa_tickets
      SET is_verified = true, verified_at = now(), status = CASE WHEN status = 'new' THEN 'confirmed' ELSE status END
      WHERE id = p_ticket_id AND NOT is_verified;
  END IF;

  -- Recalculate priority
  PERFORM public.qa_recalculate_priority(p_ticket_id);

  -- Award XP for voting
  UPDATE public.qa_tester_stats
    SET votes_cast = votes_cast + 1
    WHERE user_id = v_user_id;
  INSERT INTO public.qa_tester_stats (user_id, votes_cast)
    VALUES (v_user_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET votes_cast = qa_tester_stats.votes_cast + 1;

  RETURN jsonb_build_object('success', true, 'action', 'added', 'verification_count', v_new_count);
END;
$$ LANGUAGE plpgsql;

-- Recalculate priority score
CREATE OR REPLACE FUNCTION public.qa_recalculate_priority(p_ticket_id UUID)
RETURNS VOID AS $$
DECLARE
  v_severity_weight NUMERIC;
  v_upvote_score NUMERIC;
  v_age_bonus NUMERIC;
  v_ticket RECORD;
BEGIN
  SELECT * INTO v_ticket FROM public.qa_tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_severity_weight := CASE v_ticket.severity
    WHEN 'cosmetic' THEN 1 WHEN 'minor' THEN 2
    WHEN 'major' THEN 5 WHEN 'critical' THEN 10
    WHEN 'blocker' THEN 20 ELSE 2 END;

  v_upvote_score := COALESCE(
    (SELECT SUM(voter_weight) FROM public.qa_votes WHERE ticket_id = p_ticket_id), 0
  );

  v_age_bonus := LEAST(5, EXTRACT(EPOCH FROM (now() - v_ticket.created_at)) / 86400.0);

  UPDATE public.qa_tickets
    SET priority_score = ROUND((v_severity_weight * 10 + v_upvote_score * 5 + v_age_bonus)::NUMERIC, 2)
    WHERE id = p_ticket_id;
END;
$$ LANGUAGE plpgsql;

-- Resolve QA ticket with rewards
CREATE OR REPLACE FUNCTION public.resolve_qa_ticket(
  p_ticket_id UUID,
  p_status TEXT,
  p_notes TEXT DEFAULT NULL,
  p_reward_xp INTEGER DEFAULT 0,
  p_reward_credits INTEGER DEFAULT 0
)
RETURNS JSONB AS $$
DECLARE
  v_admin_id UUID;
  v_reporter_id UUID;
  v_old_status TEXT;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT reporter_id, status INTO v_reporter_id, v_old_status
    FROM public.qa_tickets WHERE id = p_ticket_id;
  IF v_reporter_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ticket not found');
  END IF;

  -- Update ticket
  UPDATE public.qa_tickets SET
    status = p_status,
    resolution_notes = COALESCE(p_notes, resolution_notes),
    resolved_by = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN v_admin_id ELSE resolved_by END,
    resolved_at = CASE WHEN p_status IN ('fixed', 'wont_fix', 'closed') THEN now() ELSE resolved_at END,
    reward_xp = CASE WHEN p_reward_xp > 0 THEN p_reward_xp ELSE reward_xp END,
    reward_credits = CASE WHEN p_reward_credits > 0 THEN p_reward_credits ELSE reward_credits END
  WHERE id = p_ticket_id;

  -- Award reporter
  IF p_reward_xp > 0 OR p_reward_credits > 0 THEN
    INSERT INTO public.qa_tester_stats (user_id, xp_earned, credits_earned)
      VALUES (v_reporter_id, p_reward_xp, p_reward_credits)
      ON CONFLICT (user_id) DO UPDATE SET
        xp_earned = qa_tester_stats.xp_earned + p_reward_xp,
        credits_earned = qa_tester_stats.credits_earned + p_reward_credits;

    -- Also award XP via reputation system if available
    BEGIN
      PERFORM public.award_xp(v_reporter_id, 'qa_report_resolved', p_reward_xp, 0, 'general');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  -- Update stats based on resolution
  IF p_status = 'fixed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_confirmed)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET
        reports_confirmed = qa_tester_stats.reports_confirmed + 1;
  ELSIF p_status = 'wont_fix' OR p_status = 'closed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_rejected)
      VALUES (v_reporter_id, 1)
      ON CONFLICT (user_id) DO UPDATE SET
        reports_rejected = qa_tester_stats.reports_rejected + 1;
  END IF;

  -- Recalculate accuracy and tier
  PERFORM public.qa_update_tester_tier(v_reporter_id);

  -- System comment
  INSERT INTO public.qa_comments (ticket_id, user_id, message, is_staff, is_system)
    VALUES (p_ticket_id, v_admin_id,
      CASE p_status
        WHEN 'fixed' THEN 'Баг исправлен. ' || COALESCE(p_notes, '')
        WHEN 'wont_fix' THEN 'Не будет исправлено. ' || COALESCE(p_notes, '')
        WHEN 'duplicate' THEN 'Дубликат. ' || COALESCE(p_notes, '')
        WHEN 'closed' THEN 'Закрыт. ' || COALESCE(p_notes, '')
        ELSE 'Статус изменён на ' || p_status || '. ' || COALESCE(p_notes, '')
      END, true, true);

  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$ LANGUAGE plpgsql;

-- Update tester tier
CREATE OR REPLACE FUNCTION public.qa_update_tester_tier(p_user_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_stats RECORD;
  v_new_tier TEXT;
  v_accuracy NUMERIC;
BEGIN
  SELECT * INTO v_stats FROM public.qa_tester_stats WHERE user_id = p_user_id;
  IF NOT FOUND THEN RETURN 'contributor'; END IF;

  -- Calculate accuracy
  IF (v_stats.reports_confirmed + v_stats.reports_rejected) > 0 THEN
    v_accuracy := v_stats.reports_confirmed::NUMERIC / (v_stats.reports_confirmed + v_stats.reports_rejected);
  ELSE
    v_accuracy := 0;
  END IF;

  -- Determine tier
  IF v_stats.reports_confirmed >= 20 AND v_accuracy >= 0.8 THEN
    v_new_tier := 'core_qa';
  ELSIF v_stats.reports_confirmed >= 5 AND v_accuracy >= 0.6 THEN
    v_new_tier := 'bug_hunter';
  ELSE
    v_new_tier := 'contributor';
  END IF;

  -- Update
  UPDATE public.qa_tester_stats SET
    tier = v_new_tier,
    accuracy_rate = ROUND(v_accuracy, 3),
    tier_updated_at = CASE WHEN tier != v_new_tier THEN now() ELSE tier_updated_at END
  WHERE user_id = p_user_id;

  RETURN v_new_tier;
END;
$$ LANGUAGE plpgsql;

-- Get QA dashboard stats (admin)
CREATE OR REPLACE FUNCTION public.get_qa_dashboard_stats()
RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total', COUNT(*),
    'new', COUNT(*) FILTER (WHERE status = 'new'),
    'confirmed', COUNT(*) FILTER (WHERE status = 'confirmed'),
    'triaged', COUNT(*) FILTER (WHERE status = 'triaged'),
    'in_progress', COUNT(*) FILTER (WHERE status = 'in_progress'),
    'fixed', COUNT(*) FILTER (WHERE status = 'fixed'),
    'closed', COUNT(*) FILTER (WHERE status IN ('closed', 'wont_fix', 'duplicate')),
    'critical', COUNT(*) FILTER (WHERE severity IN ('critical', 'blocker')),
    'verified', COUNT(*) FILTER (WHERE is_verified = true),
    'avg_resolution_hours', ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))/3600) FILTER (WHERE resolved_at IS NOT NULL)::NUMERIC, 1),
    'today', COUNT(*) FILTER (WHERE created_at::DATE = CURRENT_DATE),
    'this_week', COUNT(*) FILTER (WHERE created_at >= date_trunc('week', CURRENT_DATE))
  ) INTO v_result
  FROM public.qa_tickets;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- Get QA leaderboard
CREATE OR REPLACE FUNCTION public.get_qa_leaderboard(p_limit INTEGER DEFAULT 20)
RETURNS TABLE(
  user_id UUID,
  username TEXT,
  avatar_url TEXT,
  tier TEXT,
  reports_confirmed INTEGER,
  reports_total INTEGER,
  accuracy_rate NUMERIC,
  xp_earned INTEGER,
  credits_earned INTEGER,
  streak_days INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.user_id,
    p.username,
    p.avatar_url,
    s.tier,
    s.reports_confirmed,
    s.reports_total,
    s.accuracy_rate,
    s.xp_earned,
    s.credits_earned,
    s.streak_days
  FROM public.qa_tester_stats s
  LEFT JOIN public.profiles p ON p.user_id = s.user_id
  WHERE s.reports_total > 0
  ORDER BY s.reports_confirmed DESC, s.accuracy_rate DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.qa_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_bounties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_tester_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_config ENABLE ROW LEVEL SECURITY;

-- QA Tickets: everyone can read, authenticated can create, admins can update
CREATE POLICY "qa_tickets_select" ON public.qa_tickets
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_tickets_insert" ON public.qa_tickets
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = reporter_id);
CREATE POLICY "qa_tickets_update_admin" ON public.qa_tickets
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin') OR auth.uid() = reporter_id);

-- QA Comments: everyone can read, authenticated can create
CREATE POLICY "qa_comments_select" ON public.qa_comments
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_comments_insert" ON public.qa_comments
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- QA Votes: everyone can read, authenticated can manage own
CREATE POLICY "qa_votes_select" ON public.qa_votes
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_votes_insert" ON public.qa_votes
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "qa_votes_delete" ON public.qa_votes
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- QA Bounties: everyone can read, admins can manage
CREATE POLICY "qa_bounties_select" ON public.qa_bounties
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_bounties_manage" ON public.qa_bounties
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- QA Tester Stats: everyone can read own + leaderboard, system updates
CREATE POLICY "qa_tester_stats_select" ON public.qa_tester_stats
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_tester_stats_insert" ON public.qa_tester_stats
  FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "qa_tester_stats_update" ON public.qa_tester_stats
  FOR UPDATE TO authenticated USING (true);

-- QA Config: everyone can read, admins can manage
CREATE POLICY "qa_config_select" ON public.qa_config
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "qa_config_manage" ON public.qa_config
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- ============================================================
-- 5. SEED DATA
-- ============================================================

-- Default config
INSERT INTO public.qa_config (key, value, label, description) VALUES
  ('general', '{"confirmation_threshold": 3, "max_reports_per_day": 10, "min_description_length": 30, "cooldown_minutes": 5, "dedup_threshold": 0.35, "auto_triage": true}',
   'General Settings', 'Core QA system parameters'),
  ('tiers', '{"contributor": {"min_confirmed": 0, "min_accuracy": 0, "vote_weight": 1.0, "label": "Contributor"}, "bug_hunter": {"min_confirmed": 5, "min_accuracy": 0.6, "vote_weight": 1.5, "label": "Bug Hunter"}, "core_qa": {"min_confirmed": 20, "min_accuracy": 0.8, "vote_weight": 2.0, "label": "Core QA"}}',
   'Tester Tiers', 'Tier requirements and weights'),
  ('rewards', '{"cosmetic_xp": 5, "minor_xp": 10, "major_xp": 25, "critical_xp": 50, "blocker_xp": 100, "vote_xp": 2, "cosmetic_credits": 0, "minor_credits": 0, "major_credits": 5, "critical_credits": 15, "blocker_credits": 30}',
   'Reward Settings', 'XP and credit rewards by severity'),
  ('categories', '{"frontend": {"label": "Frontend / UI", "icon": "Monitor", "color": "blue"}, "backend": {"label": "Backend / API", "icon": "Server", "color": "green"}, "ai_model": {"label": "AI Model", "icon": "Cpu", "color": "purple"}, "audio": {"label": "Audio / Player", "icon": "Headphones", "color": "orange"}, "performance": {"label": "Performance", "icon": "Zap", "color": "yellow"}, "security": {"label": "Security", "icon": "Shield", "color": "red"}, "ui": {"label": "UX / Design", "icon": "Palette", "color": "pink"}, "other": {"label": "Other", "icon": "HelpCircle", "color": "gray"}}',
   'Categories', 'Ticket category definitions')
ON CONFLICT (key) DO NOTHING;

-- Default bounty
INSERT INTO public.qa_bounties (title, description, category, severity_min, reward_xp, reward_credits, max_claims, is_active, created_by)
SELECT
  'Critical Bug Bounty',
  'Find and report critical bugs that affect core functionality. Rewards: 100 XP + 30 credits per confirmed report.',
  NULL,
  'critical',
  100,
  30,
  50,
  true,
  (SELECT user_id FROM public.profiles WHERE role IN ('admin', 'super_admin') LIMIT 1)
WHERE NOT EXISTS (SELECT 1 FROM public.qa_bounties WHERE title = 'Critical Bug Bounty');
