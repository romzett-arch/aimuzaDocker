-- Drop legacy count-based escalation trigger (superseded by points-based trg_apply_warning_points)
DROP TRIGGER IF EXISTS trg_forum_warning_auto_escalate ON public.forum_warnings;
DROP FUNCTION IF EXISTS public.forum_warning_auto_escalate();