-- Preserve awarded ticket data while allowing administrators to delete a
-- bounty program. The program reference is cleared; rewards and ledger rows
-- remain immutable historical records.

UPDATE public.qa_tickets AS ticket
SET bounty_id = NULL
WHERE bounty_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.qa_bounties AS bounty WHERE bounty.id = ticket.bounty_id
  );

ALTER TABLE public.qa_tickets
  DROP CONSTRAINT IF EXISTS qa_tickets_bounty_id_fkey;

ALTER TABLE public.qa_tickets
  ADD CONSTRAINT qa_tickets_bounty_id_fkey
  FOREIGN KEY (bounty_id)
  REFERENCES public.qa_bounties(id)
  ON DELETE SET NULL;

