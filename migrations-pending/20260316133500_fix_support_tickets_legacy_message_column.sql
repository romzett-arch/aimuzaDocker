-- Нормализует старую схему support_tickets, где message оставался обязательным.
-- Актуальный поток хранит первое сообщение в public.ticket_messages.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'support_tickets'
      AND column_name = 'message'
  ) THEN
    ALTER TABLE public.support_tickets
      ALTER COLUMN message DROP NOT NULL;
  END IF;
END $$;
