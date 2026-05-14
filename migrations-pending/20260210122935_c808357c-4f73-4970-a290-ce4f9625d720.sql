-- Drop legacy duplicate notification trigger
DROP TRIGGER IF EXISTS trigger_forum_notify_on_reply ON public.forum_posts;
DROP FUNCTION IF EXISTS forum_notify_on_reply();