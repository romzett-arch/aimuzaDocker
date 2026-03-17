-- Расширяет мгновенные уведомления раздела поддержки для всей администрации:
-- отдельный поток для обычных тикетов и отдельный для багрепортов.

CREATE OR REPLACE FUNCTION public.notify_admins_new_ticket()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff RECORD;
  v_user_name TEXT;
BEGIN
  SELECT COALESCE(username, 'Пользователь') INTO v_user_name
  FROM public.profiles
  WHERE user_id = NEW.user_id;

  FOR v_staff IN
    SELECT DISTINCT user_id
    FROM public.user_roles
    WHERE role IN ('admin', 'super_admin', 'moderator')
  LOOP
    IF v_staff.user_id <> NEW.user_id THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (
        v_staff.user_id,
        'new_ticket',
        'Новый тикет ' || COALESCE(NEW.ticket_number, LEFT(NEW.id::TEXT, 8)),
        v_user_name || ': "' || LEFT(COALESCE(NEW.subject, 'Без темы'), 80) || '"',
        NEW.user_id,
        'ticket',
        NEW.id
      );
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_new_ticket_notify_admins ON public.support_tickets;
CREATE TRIGGER on_new_ticket_notify_admins
  AFTER INSERT ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_admins_new_ticket();

CREATE OR REPLACE FUNCTION public.notify_staff_new_qa_ticket()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff RECORD;
  v_user_name TEXT;
BEGIN
  SELECT COALESCE(username, 'Пользователь') INTO v_user_name
  FROM public.profiles
  WHERE user_id = NEW.reporter_id;

  FOR v_staff IN
    SELECT DISTINCT user_id
    FROM public.user_roles
    WHERE role IN ('admin', 'super_admin', 'moderator')
  LOOP
    IF v_staff.user_id <> NEW.reporter_id THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (
        v_staff.user_id,
        'new_qa_ticket',
        'Новый багрепорт ' || COALESCE(NEW.ticket_number, LEFT(NEW.id::TEXT, 8)),
        v_user_name || ': "' || LEFT(COALESCE(NEW.title, 'Без названия'), 80) || '"',
        NEW.reporter_id,
        'qa_ticket',
        NEW.id
      );
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_new_qa_ticket_notify_staff ON public.qa_tickets;
CREATE TRIGGER on_new_qa_ticket_notify_staff
  AFTER INSERT ON public.qa_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_staff_new_qa_ticket();
