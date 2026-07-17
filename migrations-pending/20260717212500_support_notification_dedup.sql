-- Keep a single, complete user notification for each support reply.

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
    v_title := public.lifecycle_notification_title_for_support(NEW.status);
    v_message := CASE NEW.status
      WHEN 'in_progress' THEN 'Команда изучает ваше обращение ' || NEW.ticket_number || '.'
      WHEN 'waiting_response' THEN 'По тикету ' || NEW.ticket_number || ' нужен ваш ответ, чтобы продолжить работу.'
      WHEN 'resolved' THEN 'Обращение ' || NEW.ticket_number || ' помечено как решённое.'
      WHEN 'closed' THEN 'Обращение ' || NEW.ticket_number || ' закрыто.'
      ELSE 'Статус обращения обновлён.'
    END;

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

    -- waiting_response is produced by a staff message. The message trigger below
    -- sends one combined notification instead of a second status notification.
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

CREATE OR REPLACE FUNCTION public.notify_support_ticket_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket RECORD;
  v_event_title TEXT;
BEGIN
  SELECT id, user_id, ticket_number, subject
  INTO v_ticket
  FROM public.support_tickets
  WHERE id = NEW.ticket_id;

  v_event_title := CASE
    WHEN COALESCE(NEW.is_staff_reply, false) THEN 'Ответ поддержки'
    ELSE 'Ответ пользователя'
  END;

  PERFORM public.create_support_ticket_event(
    NEW.ticket_id,
    CASE WHEN COALESCE(NEW.is_staff_reply, false) THEN 'message_from_staff' ELSE 'message_from_user' END,
    v_event_title,
    LEFT(NEW.message, 240),
    NULL,
    NULL,
    NEW.user_id,
    jsonb_build_object('message_preview', LEFT(NEW.message, 120))
  );

  IF COALESCE(NEW.is_staff_reply, false) THEN
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
    VALUES (
      v_ticket.user_id,
      'ticket_reply',
      'Ответ поддержки · ' || COALESCE(v_ticket.ticket_number, LEFT(v_ticket.id::TEXT, 8)),
      'По обращению «' || LEFT(v_ticket.subject, 60) || '» получен новый ответ. Откройте тикет и ответьте поддержке, чтобы продолжить работу.',
      NEW.user_id,
      'ticket',
      NEW.ticket_id,
      '/support?ticket=' || NEW.ticket_id::TEXT,
      jsonb_build_object(
        'ticket_number', v_ticket.ticket_number,
        'status', 'waiting_response',
        'message_preview', LEFT(NEW.message, 140)
      )
    );
  END IF;

  RETURN NEW;
END;
$$;
