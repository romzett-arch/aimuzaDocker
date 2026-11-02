-- Ticket numbers are global, while reporters can read only their own tickets.
-- Allocate with full visibility and serialize allocations until commit.
CREATE OR REPLACE FUNCTION public.qa_generate_ticket_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  next_num bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('public.qa_tickets.ticket_number', 0));
  SELECT coalesce(max(substring(ticket_number FROM '^QA-([0-9]+)$')::bigint), 0) + 1
  INTO next_num
  FROM public.qa_tickets
  WHERE ticket_number ~ '^QA-[0-9]+$';
  NEW.ticket_number := 'QA-' || lpad(next_num::text, greatest(6, length(next_num::text)), '0');
  RETURN NEW;
END;
$$;
