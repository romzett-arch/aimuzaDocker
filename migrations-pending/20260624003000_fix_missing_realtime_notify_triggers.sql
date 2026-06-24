-- Ensure every table used by frontend postgres_changes subscriptions emits NOTIFY events.

DROP TRIGGER IF EXISTS trg_notify_qa_tickets ON public.qa_tickets;
CREATE TRIGGER trg_notify_qa_tickets
AFTER INSERT OR UPDATE OR DELETE ON public.qa_tickets
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_radio_slots ON public.radio_slots;
CREATE TRIGGER trg_notify_radio_slots
AFTER INSERT OR UPDATE OR DELETE ON public.radio_slots
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_radio_bids ON public.radio_bids;
CREATE TRIGGER trg_notify_radio_bids
AFTER INSERT OR UPDATE OR DELETE ON public.radio_bids
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

DROP TRIGGER IF EXISTS trg_notify_radio_predictions ON public.radio_predictions;
CREATE TRIGGER trg_notify_radio_predictions
AFTER INSERT OR UPDATE OR DELETE ON public.radio_predictions
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();
