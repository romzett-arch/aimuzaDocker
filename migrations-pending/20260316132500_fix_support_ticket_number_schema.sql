-- Восстанавливает колонку ticket_number и триггер генерации номера тикета.
-- Миграция идемпотентна: безопасна для повторного запуска.

ALTER TABLE public.support_tickets
  ADD COLUMN IF NOT EXISTS ticket_number TEXT;

WITH missing_ticket_numbers AS (
  SELECT
    id,
    'TKT-' || TO_CHAR(COALESCE(created_at, now()), 'YY') || '-' || UPPER(SUBSTRING(MD5(id::TEXT) FROM 1 FOR 6)) AS generated_ticket_number
  FROM public.support_tickets
  WHERE ticket_number IS NULL OR BTRIM(ticket_number) = ''
)
UPDATE public.support_tickets AS tickets
SET ticket_number = missing_ticket_numbers.generated_ticket_number
FROM missing_ticket_numbers
WHERE tickets.id = missing_ticket_numbers.id;

CREATE OR REPLACE FUNCTION public.generate_ticket_number()
RETURNS TRIGGER AS $$
DECLARE
  current_year TEXT;
  next_number INTEGER;
BEGIN
  IF NEW.ticket_number IS NOT NULL
     AND BTRIM(NEW.ticket_number) <> ''
     AND NEW.ticket_number <> 'AUTO' THEN
    RETURN NEW;
  END IF;

  current_year := TO_CHAR(COALESCE(NEW.created_at, now()), 'YY');

  SELECT COALESCE(
    MAX((regexp_match(ticket_number, '^TKT-' || current_year || '-([0-9]{5})$'))[1]::INTEGER),
    0
  ) + 1
  INTO next_number
  FROM public.support_tickets
  WHERE ticket_number ~ ('^TKT-' || current_year || '-[0-9]{5}$');

  NEW.ticket_number := 'TKT-' || current_year || '-' || LPAD(next_number::TEXT, 5, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS set_ticket_number ON public.support_tickets;
DROP TRIGGER IF EXISTS generate_ticket_number_trigger ON public.support_tickets;

CREATE TRIGGER generate_ticket_number_trigger
BEFORE INSERT ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.generate_ticket_number();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'support_tickets_ticket_number_key'
      AND conrelid = 'public.support_tickets'::regclass
  ) THEN
    ALTER TABLE public.support_tickets
      ADD CONSTRAINT support_tickets_ticket_number_key UNIQUE (ticket_number);
  END IF;
END $$;

ALTER TABLE public.support_tickets
  ALTER COLUMN ticket_number SET NOT NULL;
