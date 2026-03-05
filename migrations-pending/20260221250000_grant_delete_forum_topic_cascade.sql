-- Grant EXECUTE on admin RPCs to authenticated users.
-- Each RPC checks admin/moderator role internally (user_roles, is_admin).
-- Without these GRANTs, admins could not call the RPCs from the client.

-- Forum moderation
GRANT EXECUTE ON FUNCTION public.delete_forum_topic_cascade(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_moderate_promo(UUID, UUID, TEXT, TEXT) TO authenticated;

-- Admin conversations
GRANT EXECUTE ON FUNCTION public.create_admin_conversation(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_admin_conversation(UUID) TO authenticated;

-- User management
GRANT EXECUTE ON FUNCTION public.get_user_emails() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_add_xp(UUID, NUMERIC, TEXT, BOOLEAN) TO authenticated;

-- Contest moderation
GRANT EXECUTE ON FUNCTION public.hide_contest_comment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unhide_contest_comment(UUID) TO authenticated;

-- Voting / moderation
GRANT EXECUTE ON FUNCTION public.send_track_to_voting(UUID, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_track_voting(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_voting_forum_topic(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_voting_topic_on_rejection(UUID, TEXT) TO authenticated;

-- Voting admin dashboard
GRANT EXECUTE ON FUNCTION public.admin_get_voting_dashboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_active_votings(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_flagged_votes(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_annul_vote(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_end_voting_early(UUID, TEXT, TEXT) TO authenticated;

-- Radio admin
GRANT EXECUTE ON FUNCTION public.radio_resolve_predictions() TO authenticated;

-- Error logs
GRANT EXECUTE ON FUNCTION public.cleanup_old_logs() TO authenticated;

-- RLS: admins/mods see ALL forum topics (including hidden) for admin panel
DROP POLICY IF EXISTS "Admins view all topics" ON public.forum_topics;
CREATE POLICY "Admins view all topics" ON public.forum_topics
  FOR SELECT USING (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
    OR public.has_role(auth.uid(), 'moderator')
  );
