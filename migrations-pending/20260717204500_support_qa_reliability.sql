-- Support/QA reliability and notification delivery hardening.

ALTER TABLE public.ticket_messages
  ADD COLUMN IF NOT EXISTS is_staff_reply BOOLEAN;

UPDATE public.ticket_messages
SET is_staff_reply = COALESCE(is_staff, false)
WHERE is_staff_reply IS NULL;

ALTER TABLE public.ticket_messages
  ALTER COLUMN is_staff_reply SET DEFAULT false,
  ALTER COLUMN is_staff_reply SET NOT NULL;

ALTER TABLE public.ticket_messages
  ALTER COLUMN is_staff SET DEFAULT false;

CREATE OR REPLACE FUNCTION public.create_support_ticket(
  p_category TEXT,
  p_priority TEXT,
  p_subject TEXT,
  p_message TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ticket public.support_tickets%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  IF p_category NOT IN ('bug', 'feature', 'payment', 'account', 'generation', 'other') THEN
    RAISE EXCEPTION 'Некорректная категория тикета';
  END IF;

  IF p_priority NOT IN ('low', 'medium', 'high', 'urgent') THEN
    RAISE EXCEPTION 'Некорректный приоритет тикета';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_subject, '')), '') IS NULL
     OR CHAR_LENGTH(BTRIM(p_subject)) > 200 THEN
    RAISE EXCEPTION 'Тема тикета должна содержать от 1 до 200 символов';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_message, '')), '') IS NULL
     OR CHAR_LENGTH(BTRIM(p_message)) > 10000 THEN
    RAISE EXCEPTION 'Сообщение должно содержать от 1 до 10000 символов';
  END IF;

  INSERT INTO public.support_tickets (user_id, category, priority, subject, status)
  VALUES (v_user_id, p_category, p_priority, BTRIM(p_subject), 'open')
  RETURNING * INTO v_ticket;

  INSERT INTO public.ticket_messages (ticket_id, user_id, message, is_staff, is_staff_reply)
  VALUES (v_ticket.id, v_user_id, BTRIM(p_message), false, false);

  RETURN to_jsonb(v_ticket);
END;
$$;

REVOKE ALL ON FUNCTION public.create_support_ticket(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_support_ticket(TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.support_ticket_message_state_and_staff_notify()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket public.support_tickets%ROWTYPE;
  v_staff RECORD;
  v_is_staff BOOLEAN := COALESCE(NEW.is_staff_reply, false) OR COALESCE(NEW.is_staff, false);
  v_is_first_message BOOLEAN;
BEGIN
  SELECT * INTO v_ticket FROM public.support_tickets WHERE id = NEW.ticket_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT COUNT(*) = 1 INTO v_is_first_message
  FROM public.ticket_messages
  WHERE ticket_id = NEW.ticket_id;

  IF v_is_staff THEN
    UPDATE public.support_tickets
    SET status = CASE WHEN status IN ('open', 'in_progress') THEN 'waiting_response' ELSE status END,
        assigned_to = COALESCE(assigned_to, NEW.user_id),
        updated_at = now()
    WHERE id = NEW.ticket_id AND status NOT IN ('resolved', 'closed');
  ELSE
    UPDATE public.support_tickets
    SET status = CASE WHEN status = 'waiting_response' THEN 'in_progress' ELSE status END,
        updated_at = now()
    WHERE id = NEW.ticket_id AND status NOT IN ('resolved', 'closed');

    FOR v_staff IN
      SELECT DISTINCT user_id FROM public.user_roles
      WHERE role IN ('moderator', 'admin', 'super_admin')
    LOOP
      IF NOT v_is_first_message AND v_staff.user_id <> NEW.user_id THEN
        INSERT INTO public.notifications (
          user_id, type, title, message, actor_id, target_type, target_id, link, metadata
        ) VALUES (
          v_staff.user_id,
          'ticket_user_reply',
          'Новое сообщение в тикете ' || COALESCE(v_ticket.ticket_number, LEFT(v_ticket.id::TEXT, 8)),
          LEFT(NEW.message, 140),
          NEW.user_id,
          'ticket',
          NEW.ticket_id,
          '/admin/support?tab=tickets&ticket=' || NEW.ticket_id::TEXT,
          jsonb_build_object('ticket_number', v_ticket.ticket_number, 'subject', v_ticket.subject)
        );
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS support_ticket_message_state_trigger ON public.ticket_messages;
CREATE TRIGGER support_ticket_message_state_trigger
AFTER INSERT ON public.ticket_messages
FOR EACH ROW EXECUTE FUNCTION public.support_ticket_message_state_and_staff_notify();

CREATE OR REPLACE FUNCTION public.qa_ticket_stats_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.qa_tester_stats (user_id, reports_total, reports_critical, last_report_at)
  VALUES (
    NEW.reporter_id, 1,
    CASE WHEN NEW.severity IN ('critical', 'blocker') THEN 1 ELSE 0 END,
    NEW.created_at
  )
  ON CONFLICT (user_id) DO UPDATE SET
    reports_total = COALESCE(qa_tester_stats.reports_total, 0) + 1,
    reports_critical = COALESCE(qa_tester_stats.reports_critical, 0)
      + CASE WHEN NEW.severity IN ('critical', 'blocker') THEN 1 ELSE 0 END,
    last_report_at = GREATEST(COALESCE(qa_tester_stats.last_report_at, NEW.created_at), NEW.created_at);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qa_ticket_stats_insert_trigger ON public.qa_tickets;
CREATE TRIGGER qa_ticket_stats_insert_trigger
AFTER INSERT ON public.qa_tickets
FOR EACH ROW EXECUTE FUNCTION public.qa_ticket_stats_after_insert();

REVOKE ALL ON FUNCTION public.resolve_qa_ticket(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_qa_ticket(UUID, TEXT, TEXT, INTEGER, INTEGER) TO service_role;

ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS support_tickets_owner_read ON public.support_tickets;
CREATE POLICY support_tickets_owner_read ON public.support_tickets
FOR SELECT TO authenticated
USING (
  user_id = auth.uid() OR public.has_role(auth.uid(), 'moderator')
  OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin')
);

DROP POLICY IF EXISTS support_tickets_owner_insert ON public.support_tickets;
CREATE POLICY support_tickets_owner_insert ON public.support_tickets
AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS support_tickets_staff_update ON public.support_tickets;
CREATE POLICY support_tickets_staff_update ON public.support_tickets
FOR UPDATE TO authenticated
USING (
  user_id = auth.uid() OR public.has_role(auth.uid(), 'moderator')
  OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin')
)
WITH CHECK (
  user_id = auth.uid() OR public.has_role(auth.uid(), 'moderator')
  OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin')
);

DROP POLICY IF EXISTS ticket_messages_participant_read ON public.ticket_messages;
CREATE POLICY ticket_messages_participant_read ON public.ticket_messages
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.support_tickets st
    WHERE st.id = ticket_messages.ticket_id
      AND (
        st.user_id = auth.uid() OR public.has_role(auth.uid(), 'moderator')
        OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

DROP POLICY IF EXISTS ticket_messages_participant_insert ON public.ticket_messages;
CREATE POLICY ticket_messages_participant_insert ON public.ticket_messages
FOR INSERT TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.support_tickets st
    WHERE st.id = ticket_messages.ticket_id
      AND (
        st.user_id = auth.uid() OR public.has_role(auth.uid(), 'moderator')
        OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

GRANT SELECT, INSERT, UPDATE ON public.support_tickets TO authenticated;
GRANT SELECT, INSERT ON public.ticket_messages TO authenticated;
