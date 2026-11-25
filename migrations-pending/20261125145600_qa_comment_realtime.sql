-- Publish appended QA comments through the existing PostgreSQL notification channel.
CREATE OR REPLACE TRIGGER trg_notify_qa_comments
AFTER INSERT ON public.qa_comments
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();
