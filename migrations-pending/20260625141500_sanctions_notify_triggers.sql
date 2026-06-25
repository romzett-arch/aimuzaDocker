DROP TRIGGER IF EXISTS trg_notify_user_blocks_changes ON public.user_blocks;
CREATE TRIGGER trg_notify_user_blocks_changes
AFTER INSERT OR UPDATE OR DELETE ON public.user_blocks
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_forum_user_bans_changes ON public.forum_user_bans;
CREATE TRIGGER trg_notify_forum_user_bans_changes
AFTER INSERT OR UPDATE OR DELETE ON public.forum_user_bans
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_forum_warnings_changes ON public.forum_warnings;
CREATE TRIGGER trg_notify_forum_warnings_changes
AFTER INSERT OR UPDATE OR DELETE ON public.forum_warnings
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();
