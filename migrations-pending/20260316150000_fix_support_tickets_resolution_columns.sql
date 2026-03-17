-- Восстанавливает поля старой схемы support_tickets, нужные для закрытия тикетов.
-- Идемпотентно: безопасно для повторного применения.

ALTER TABLE public.support_tickets
  ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;

ALTER TABLE public.support_tickets
  ADD COLUMN IF NOT EXISTS assigned_to UUID;
