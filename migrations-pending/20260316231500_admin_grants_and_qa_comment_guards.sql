-- Админские начисления в доходы пользователя + блокировка комментариев в закрытых QA-репортах.

ALTER TABLE public.seller_earnings
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.admin_grant_user_income(
  p_user_id UUID,
  p_amount INTEGER,
  p_source_name TEXT,
  p_purpose TEXT,
  p_comment TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
  v_grant_id UUID := gen_random_uuid();
  v_source_name TEXT := NULLIF(BTRIM(COALESCE(p_source_name, '')), '');
  v_purpose TEXT := NULLIF(BTRIM(COALESCE(p_purpose, '')), '');
  v_comment TEXT := NULLIF(BTRIM(COALESCE(p_comment, '')), '');
  v_description TEXT;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  IF NOT (
    public.has_role(v_admin_id, 'admin')
    OR public.has_role(v_admin_id, 'super_admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно прав');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Сумма должна быть больше нуля');
  END IF;

  IF v_source_name IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Укажите, от кого поступление');
  END IF;

  IF v_purpose IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Укажите, за что поступление');
  END IF;

  SELECT COALESCE(balance, 0)
  INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Пользователь не найден');
  END IF;

  v_description := 'Поступило ' || p_amount::TEXT || ' ₽ от ' || v_source_name || ' за ' || v_purpose;

  IF v_comment IS NOT NULL THEN
    v_description := v_description || '. ' || v_comment;
  END IF;

  UPDATE public.profiles
  SET balance = COALESCE(balance, 0) + p_amount
  WHERE user_id = p_user_id
  RETURNING balance INTO v_balance_after;

  INSERT INTO public.balance_transactions (
    user_id,
    amount,
    balance_before,
    balance_after,
    type,
    description,
    reference_id,
    reference_type,
    metadata
  )
  VALUES (
    p_user_id,
    p_amount,
    v_balance_before,
    v_balance_after,
    'sale_income',
    v_description,
    v_grant_id,
    'admin_grant',
    jsonb_build_object(
      'source_name', v_source_name,
      'purpose', v_purpose,
      'comment', v_comment,
      'granted_by', v_admin_id
    )
  );

  INSERT INTO public.seller_earnings (
    user_id,
    amount,
    source_type,
    source_id,
    platform_fee,
    net_amount,
    status,
    metadata
  )
  VALUES (
    p_user_id,
    p_amount,
    'admin_grant',
    v_grant_id,
    -p_amount,
    p_amount,
    'available',
    jsonb_build_object(
      'source_name', v_source_name,
      'purpose', v_purpose,
      'comment', v_comment,
      'granted_by', v_admin_id
    )
  );

  INSERT INTO public.notifications (
    user_id,
    type,
    title,
    message,
    actor_id,
    target_type,
    target_id,
    metadata
  )
  VALUES (
    p_user_id,
    'system',
    'Начисление от администрации',
    v_description,
    v_admin_id,
    'profile',
    p_user_id,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'amount', p_amount,
      'source_name', v_source_name,
      'purpose', v_purpose
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'grant_id', v_grant_id,
    'balance_before', v_balance_before,
    'balance_after', v_balance_after,
    'amount', p_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_grant_user_income(UUID, INTEGER, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.prevent_qa_comment_on_closed_ticket()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  IF COALESCE(NEW.is_system, false) THEN
    RETURN NEW;
  END IF;

  SELECT status
  INTO v_status
  FROM public.qa_tickets
  WHERE id = NEW.ticket_id;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Репорт закрыт и больше не принимает комментарии';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qa_comment_closed_ticket_guard ON public.qa_comments;
CREATE TRIGGER qa_comment_closed_ticket_guard
BEFORE INSERT ON public.qa_comments
FOR EACH ROW
EXECUTE FUNCTION public.prevent_qa_comment_on_closed_ticket();

CREATE OR REPLACE FUNCTION public.notify_qa_ticket_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket RECORD;
  v_staff RECORD;
BEGIN
  IF COALESCE(NEW.is_system, false) THEN
    RETURN NEW;
  END IF;

  SELECT id, reporter_id, ticket_number, title
  INTO v_ticket
  FROM public.qa_tickets
  WHERE id = NEW.ticket_id;

  PERFORM public.create_qa_ticket_event(
    NEW.ticket_id,
    CASE WHEN COALESCE(NEW.is_staff, false) THEN 'comment_from_staff' ELSE 'comment_from_user' END,
    CASE WHEN COALESCE(NEW.is_staff, false) THEN 'Комментарий команды' ELSE 'Комментарий пользователя' END,
    LEFT(NEW.message, 240),
    NULL,
    NULL,
    NEW.user_id,
    jsonb_build_object('message_preview', LEFT(NEW.message, 120))
  );

  IF COALESCE(NEW.is_staff, false) THEN
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
    VALUES (
      v_ticket.reporter_id,
      'qa_staff_reply',
      'Комментарий по баг-репорту',
      LEFT(NEW.message, 140),
      NEW.user_id,
      'qa_ticket',
      NEW.ticket_id,
      '/bug-reports?ticket=' || NEW.ticket_id::TEXT,
      jsonb_build_object('ticket_number', v_ticket.ticket_number)
    );
  ELSE
    FOR v_staff IN
      SELECT DISTINCT user_id
      FROM public.user_roles
      WHERE role IN ('admin', 'super_admin', 'moderator')
    LOOP
      IF v_staff.user_id <> NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
        VALUES (
          v_staff.user_id,
          'qa_user_comment',
          'Новый комментарий в багрепорте ' || COALESCE(v_ticket.ticket_number, LEFT(NEW.ticket_id::TEXT, 8)),
          LEFT(NEW.message, 140),
          NEW.user_id,
          'qa_ticket',
          NEW.ticket_id,
          '/admin/support?tab=bugs&ticket=' || NEW.ticket_id::TEXT,
          jsonb_build_object(
            'ticket_number', v_ticket.ticket_number,
            'ticket_title', v_ticket.title
          )
        );
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;
