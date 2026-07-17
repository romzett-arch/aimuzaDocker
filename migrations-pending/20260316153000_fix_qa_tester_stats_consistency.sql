-- Приводит qa_tester_stats в соответствие с фактическими QA-тикетами
-- и добавляет стабильный RPC для инкремента общего числа репортов.

CREATE TABLE IF NOT EXISTS public.qa_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID,
  title TEXT,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  severity TEXT,
  bounty_id UUID,
  ticket_number TEXT,
  resolution_notes TEXT,
  reward_xp INTEGER NOT NULL DEFAULT 0,
  reward_credits INTEGER NOT NULL DEFAULT 0,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.qa_tester_stats (
  user_id UUID PRIMARY KEY,
  reports_total INTEGER NOT NULL DEFAULT 0,
  reports_confirmed INTEGER NOT NULL DEFAULT 0,
  reports_rejected INTEGER NOT NULL DEFAULT 0,
  reports_critical INTEGER NOT NULL DEFAULT 0,
  accuracy_rate NUMERIC NOT NULL DEFAULT 0,
  xp_earned INTEGER NOT NULL DEFAULT 0,
  credits_earned INTEGER NOT NULL DEFAULT 0,
  last_report_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.qa_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.qa_tickets(id) ON DELETE CASCADE,
  user_id UUID,
  message TEXT NOT NULL,
  is_staff BOOLEAN NOT NULL DEFAULT false,
  is_system BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.qa_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.qa_tickets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  vote_type TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE IF EXISTS public.qa_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.qa_tester_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.qa_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.qa_votes ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.qa_increment_reports_total(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;

  INSERT INTO public.qa_tester_stats (user_id, reports_total, last_report_at)
  VALUES (p_user_id, 1, now())
  ON CONFLICT (user_id) DO UPDATE SET
    reports_total = COALESCE(public.qa_tester_stats.reports_total, 0) + 1,
    last_report_at = now();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.qa_increment_reports_total(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.qa_rebuild_tester_stats()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_affected INTEGER := 0;
  v_updated INTEGER := 0;
  v_has_tier_updater BOOLEAN := false;
  v_row RECORD;
BEGIN
  WITH aggregated AS (
    SELECT
      t.reporter_id AS user_id,
      COUNT(*)::INTEGER AS reports_total,
      COUNT(*) FILTER (WHERE t.status = 'fixed')::INTEGER AS reports_confirmed,
      COUNT(*) FILTER (WHERE t.status IN ('wont_fix', 'closed'))::INTEGER AS reports_rejected,
      COUNT(*) FILTER (WHERE t.severity IN ('critical', 'blocker'))::INTEGER AS reports_critical,
      MAX(t.created_at) AS last_report_at
    FROM public.qa_tickets t
    WHERE t.reporter_id IS NOT NULL
    GROUP BY t.reporter_id
  )
  INSERT INTO public.qa_tester_stats (
    user_id,
    reports_total,
    reports_confirmed,
    reports_rejected,
    reports_critical,
    accuracy_rate,
    last_report_at
  )
  SELECT
    a.user_id,
    a.reports_total,
    a.reports_confirmed,
    a.reports_rejected,
    a.reports_critical,
    CASE
      WHEN (a.reports_confirmed + a.reports_rejected) > 0
        THEN a.reports_confirmed::NUMERIC / (a.reports_confirmed + a.reports_rejected)::NUMERIC
      ELSE 0::NUMERIC
    END AS accuracy_rate,
    a.last_report_at
  FROM aggregated a
  ON CONFLICT (user_id) DO UPDATE SET
    reports_total = EXCLUDED.reports_total,
    reports_confirmed = EXCLUDED.reports_confirmed,
    reports_rejected = EXCLUDED.reports_rejected,
    reports_critical = EXCLUDED.reports_critical,
    accuracy_rate = EXCLUDED.accuracy_rate,
    last_report_at = EXCLUDED.last_report_at;

  GET DIAGNOSTICS v_affected = ROW_COUNT;

  UPDATE public.qa_tester_stats s
  SET
    reports_total = 0,
    reports_confirmed = 0,
    reports_rejected = 0,
    reports_critical = 0,
    accuracy_rate = 0,
    last_report_at = NULL
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.qa_tickets t
    WHERE t.reporter_id = s.user_id
  )
    AND (
      COALESCE(s.reports_total, 0) <> 0
      OR COALESCE(s.reports_confirmed, 0) <> 0
      OR COALESCE(s.reports_rejected, 0) <> 0
      OR COALESCE(s.reports_critical, 0) <> 0
      OR COALESCE(s.accuracy_rate, 0) <> 0
      OR s.last_report_at IS NOT NULL
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_affected := v_affected + v_updated;

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'qa_update_tester_tier'
  ) INTO v_has_tier_updater;

  IF v_has_tier_updater THEN
    FOR v_row IN
      SELECT user_id
      FROM public.qa_tester_stats
      WHERE COALESCE(reports_total, 0) > 0
    LOOP
      PERFORM public.qa_update_tester_tier(v_row.user_id);
    END LOOP;
  END IF;

  RETURN v_affected;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.qa_rebuild_tester_stats() TO authenticated;

SELECT public.qa_rebuild_tester_stats();
