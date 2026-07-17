-- Remove server-only legacy overloads and restore the canonical QA counter RPC.

BEGIN;

DROP FUNCTION IF EXISTS public.delete_forum_topic_cascade(UUID);
DROP FUNCTION IF EXISTS public.allocate_guaranteed_radio_slots();

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

REVOKE ALL ON FUNCTION public.qa_increment_reports_total(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qa_increment_reports_total(UUID) TO service_role;

REVOKE ALL ON FUNCTION public.delete_forum_topic_cascade(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_forum_topic_cascade(UUID, UUID, TEXT) TO service_role;

COMMIT;
