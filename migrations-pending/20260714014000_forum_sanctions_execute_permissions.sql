-- Sanction RPCs already validate the actor internally. Restrict EXECUTE too so
-- anonymous requests are rejected before entering SECURITY DEFINER code.

REVOKE ALL ON FUNCTION public.forum_issue_sanction(uuid, text, integer, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_issue_sanction(uuid, text, integer, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_issue_sanction(uuid, text, integer, text, boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.forum_lift_sanction(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_lift_sanction(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_lift_sanction(uuid, text, uuid) TO authenticated;
