-- Connect QA bounty programs to eligible reports and clarify the reversible
-- support resolution state.

CREATE OR REPLACE FUNCTION public.qa_assign_matching_bounty()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.bounty_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT bounty.id
  INTO NEW.bounty_id
  FROM public.qa_bounties AS bounty
  WHERE bounty.is_active = true
    AND bounty.claimed_count < bounty.max_claims
    AND (bounty.expires_at IS NULL OR bounty.expires_at > now())
    AND (bounty.category IS NULL OR bounty.category = NEW.category)
    AND CASE NEW.severity
      WHEN 'cosmetic' THEN 0
      WHEN 'minor' THEN 1
      WHEN 'major' THEN 2
      WHEN 'critical' THEN 3
      WHEN 'blocker' THEN 4
      ELSE -1
    END >= CASE bounty.severity_min
      WHEN 'cosmetic' THEN 0
      WHEN 'minor' THEN 1
      WHEN 'major' THEN 2
      WHEN 'critical' THEN 3
      WHEN 'blocker' THEN 4
      ELSE 99
    END
  ORDER BY
    (bounty.category = NEW.category) DESC,
    CASE bounty.severity_min
      WHEN 'blocker' THEN 4
      WHEN 'critical' THEN 3
      WHEN 'major' THEN 2
      WHEN 'minor' THEN 1
      ELSE 0
    END DESC,
    bounty.created_at DESC
  LIMIT 1;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qa_ticket_assign_matching_bounty_trigger ON public.qa_tickets;
CREATE TRIGGER qa_ticket_assign_matching_bounty_trigger
BEFORE INSERT OR UPDATE OF category, severity ON public.qa_tickets
FOR EACH ROW
EXECUTE FUNCTION public.qa_assign_matching_bounty();

CREATE OR REPLACE FUNCTION public.lifecycle_notification_title_for_support(p_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE p_status
    WHEN 'open' THEN 'Обращение принято'
    WHEN 'in_progress' THEN 'Поддержка работает над обращением'
    WHEN 'waiting_response' THEN 'Нужен ваш ответ'
    WHEN 'resolved' THEN 'Решение предложено'
    WHEN 'closed' THEN 'Тикет закрыт'
    ELSE 'Статус тикета обновлён'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_support_ticket_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_title TEXT;
  v_message TEXT;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status = 'waiting_response' AND NEW.status = 'in_progress' THEN
      v_title := 'Ответ получен';
      v_message := 'Ваше сообщение по обращению ' || NEW.ticket_number || ' передано команде. Диалог продолжается.';
    ELSIF OLD.status = 'resolved' AND NEW.status = 'in_progress' THEN
      v_title := 'Обращение возобновлено';
      v_message := 'Вы сообщили, что вопрос по ' || NEW.ticket_number || ' ещё актуален. Поддержка продолжит работу.';
    ELSE
      v_title := public.lifecycle_notification_title_for_support(NEW.status);
      v_message := CASE NEW.status
        WHEN 'in_progress' THEN 'Команда начала работу над обращением ' || NEW.ticket_number || '.'
        WHEN 'waiting_response' THEN 'По тикету ' || NEW.ticket_number || ' нужен ваш ответ, чтобы продолжить работу.'
        WHEN 'resolved' THEN 'По обращению ' || NEW.ticket_number || ' предложено решение. Если оно не помогло, ответьте в диалоге.'
        WHEN 'closed' THEN 'Обращение ' || NEW.ticket_number || ' закрыто окончательно.'
        ELSE 'Статус обращения обновлён.'
      END;
    END IF;

    PERFORM public.create_support_ticket_event(
      NEW.id,
      'status_changed',
      v_title,
      v_message,
      OLD.status,
      NEW.status,
      auth.uid(),
      jsonb_build_object('ticket_number', NEW.ticket_number)
    );

    IF NEW.status IN ('in_progress', 'resolved', 'closed') THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
      VALUES (
        NEW.user_id,
        public.lifecycle_notification_type_for_support(NEW.status),
        v_title,
        v_message,
        auth.uid(),
        'ticket',
        NEW.id,
        '/support?ticket=' || NEW.id::TEXT,
        jsonb_build_object('ticket_number', NEW.ticket_number, 'status', NEW.status)
      );
    END IF;
  END IF;

  IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to AND NEW.assigned_to IS NOT NULL THEN
    PERFORM public.create_support_ticket_event(
      NEW.id,
      'assigned',
      'Тикет назначен исполнителю',
      'У обращения появился ответственный сотрудник.',
      NULL,
      NEW.status,
      auth.uid(),
      jsonb_build_object('assigned_to', NEW.assigned_to)
    );
  END IF;

  RETURN NEW;
END;
$$;

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
    SET status = CASE WHEN status IN ('waiting_response', 'resolved') THEN 'in_progress' ELSE status END,
        updated_at = now()
    WHERE id = NEW.ticket_id AND status <> 'closed';

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

