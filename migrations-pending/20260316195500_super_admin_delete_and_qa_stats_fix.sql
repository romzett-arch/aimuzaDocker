-- Удаление тикетов/репортов доступно только super_admin.
-- QA-статистика считает подтверждённые репорты по фактическим статусам.

DROP POLICY IF EXISTS "Users can delete own tickets" ON public.support_tickets;
DROP POLICY IF EXISTS "Super admins can delete tickets" ON public.support_tickets;
CREATE POLICY "Super admins can delete tickets"
ON public.support_tickets
FOR DELETE TO authenticated
USING (public.has_role(auth.uid(), 'super_admin'));

DROP POLICY IF EXISTS "qa_tickets_delete_owner_or_admin" ON public.qa_tickets;
DROP POLICY IF EXISTS "qa_tickets_delete_super_admin" ON public.qa_tickets;
CREATE POLICY "qa_tickets_delete_super_admin"
ON public.qa_tickets
FOR DELETE TO authenticated
USING (public.has_role(auth.uid(), 'super_admin'));

DROP POLICY IF EXISTS "bug_reports_delete_super_admin" ON public.bug_reports;
CREATE POLICY "bug_reports_delete_super_admin"
ON public.bug_reports
FOR DELETE TO authenticated
USING (public.has_role(auth.uid(), 'super_admin'));

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
      COUNT(*) FILTER (WHERE t.status IN ('confirmed', 'triaged', 'in_progress', 'fixed'))::INTEGER AS reports_confirmed,
      COUNT(*) FILTER (WHERE t.status IN ('wont_fix', 'duplicate', 'closed'))::INTEGER AS reports_rejected,
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

SELECT public.qa_rebuild_tester_stats();
