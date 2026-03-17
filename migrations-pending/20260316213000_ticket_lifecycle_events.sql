-- Lifecycle events for support and QA tickets.
-- Adds timeline history, richer notifications and moves QA rewards to confirmation.

CREATE TABLE IF NOT EXISTS public.support_ticket_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  actor_id UUID,
  title TEXT NOT NULL,
  description TEXT,
  status_from TEXT,
  status_to TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.qa_ticket_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.qa_tickets(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  actor_id UUID,
  title TEXT NOT NULL,
  description TEXT,
  status_from TEXT,
  status_to TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_support_ticket_events_ticket_created
  ON public.support_ticket_events(ticket_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_qa_ticket_events_ticket_created
  ON public.qa_ticket_events(ticket_id, created_at DESC);

ALTER TABLE public.support_ticket_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_ticket_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "support_ticket_events_select" ON public.support_ticket_events;
CREATE POLICY "support_ticket_events_select"
ON public.support_ticket_events
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.support_tickets st
    WHERE st.id = support_ticket_events.ticket_id
      AND (
        st.user_id = auth.uid()
        OR public.has_role(auth.uid(), 'admin')
        OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

DROP POLICY IF EXISTS "qa_ticket_events_select" ON public.qa_ticket_events;
CREATE POLICY "qa_ticket_events_select"
ON public.qa_ticket_events
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.qa_tickets qt
    WHERE qt.id = qa_ticket_events.ticket_id
      AND (
        qt.reporter_id = auth.uid()
        OR public.has_role(auth.uid(), 'admin')
        OR public.has_role(auth.uid(), 'super_admin')
      )
  )
);

CREATE OR REPLACE FUNCTION public.lifecycle_notification_title_for_support(p_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE p_status
    WHEN 'open' THEN 'Обращение принято'
    WHEN 'in_progress' THEN 'Поддержка взяла тикет в работу'
    WHEN 'waiting_response' THEN 'Нужен ваш ответ'
    WHEN 'resolved' THEN 'Тикет решён'
    WHEN 'closed' THEN 'Тикет закрыт'
    ELSE 'Статус тикета обновлён'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.lifecycle_notification_type_for_support(p_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE p_status
    WHEN 'open' THEN 'ticket_received'
    WHEN 'in_progress' THEN 'ticket_in_progress'
    WHEN 'waiting_response' THEN 'ticket_waiting_response'
    WHEN 'resolved' THEN 'ticket_resolved'
    WHEN 'closed' THEN 'ticket_closed'
    ELSE 'system'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.lifecycle_notification_title_for_qa(p_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE p_status
    WHEN 'new' THEN 'Баг-репорт принят'
    WHEN 'confirmed' THEN 'Баг подтверждён'
    WHEN 'triaged' THEN 'Баг принят в план'
    WHEN 'in_progress' THEN 'Исправление началось'
    WHEN 'fixed' THEN 'Баг исправлен'
    WHEN 'duplicate' THEN 'Репорт помечен как дубликат'
    WHEN 'wont_fix' THEN 'Исправление не планируется'
    WHEN 'closed' THEN 'Репорт закрыт'
    ELSE 'Статус баг-репорта обновлён'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.lifecycle_notification_type_for_qa(p_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE p_status
    WHEN 'new' THEN 'qa_ticket_received'
    WHEN 'confirmed' THEN 'qa_ticket_confirmed'
    WHEN 'triaged' THEN 'qa_ticket_triaged'
    WHEN 'in_progress' THEN 'qa_ticket_in_progress'
    WHEN 'fixed' THEN 'qa_ticket_fixed'
    WHEN 'duplicate' THEN 'qa_ticket_duplicate'
    WHEN 'wont_fix' THEN 'qa_ticket_wont_fix'
    WHEN 'closed' THEN 'qa_ticket_closed'
    ELSE 'system'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_support_ticket_event(
  p_ticket_id UUID,
  p_event_type TEXT,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_status_from TEXT DEFAULT NULL,
  p_status_to TEXT DEFAULT NULL,
  p_actor_id UUID DEFAULT auth.uid(),
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  INSERT INTO public.support_ticket_events (
    ticket_id,
    event_type,
    actor_id,
    title,
    description,
    status_from,
    status_to,
    metadata
  )
  VALUES (
    p_ticket_id,
    p_event_type,
    p_actor_id,
    p_title,
    p_description,
    p_status_from,
    p_status_to,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_qa_ticket_event(
  p_ticket_id UUID,
  p_event_type TEXT,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_status_from TEXT DEFAULT NULL,
  p_status_to TEXT DEFAULT NULL,
  p_actor_id UUID DEFAULT auth.uid(),
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  INSERT INTO public.qa_ticket_events (
    ticket_id,
    event_type,
    actor_id,
    title,
    description,
    status_from,
    status_to,
    metadata
  )
  VALUES (
    p_ticket_id,
    p_event_type,
    p_actor_id,
    p_title,
    p_description,
    p_status_from,
    p_status_to,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_support_ticket_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.create_support_ticket_event(
    NEW.id,
    'created',
    'Тикет создан',
    'Обращение принято системой и ждёт ответа поддержки.',
    NULL,
    NEW.status,
    NEW.user_id,
    jsonb_build_object('ticket_number', NEW.ticket_number, 'priority', NEW.priority, 'category', NEW.category)
  );

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  VALUES (
    NEW.user_id,
    'ticket_received',
    'Тикет принят',
    'Мы получили обращение ' || NEW.ticket_number || ' и скоро ответим вам.',
    NULL,
    'ticket',
    NEW.id,
    '/support?ticket=' || NEW.id::TEXT,
    jsonb_build_object('ticket_number', NEW.ticket_number, 'status', NEW.status)
  );

  RETURN NEW;
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

    IF NEW.status IN ('in_progress', 'waiting_response', 'resolved', 'closed') THEN
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
      'Ответ на тикет ' || v_ticket.ticket_number,
      'Поддержка ответила по обращению "' || LEFT(v_ticket.subject, 60) || '".',
      NEW.user_id,
      'ticket',
      NEW.ticket_id,
      '/support?ticket=' || NEW.ticket_id::TEXT,
      jsonb_build_object('ticket_number', v_ticket.ticket_number)
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_qa_ticket_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.create_qa_ticket_event(
    NEW.id,
    'created',
    'Репорт отправлен',
    'Репорт принят и ждёт первичной проверки команды.',
    NULL,
    NEW.status,
    NEW.reporter_id,
    jsonb_build_object('ticket_number', NEW.ticket_number, 'severity', NEW.severity, 'category', NEW.category)
  );

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  VALUES (
    NEW.reporter_id,
    'qa_ticket_received',
    'Баг-репорт принят',
    'Репорт ' || COALESCE(NEW.ticket_number, LEFT(NEW.id::TEXT, 8)) || ' создан и ждёт проверки.',
    NULL,
    'qa_ticket',
    NEW.id,
    '/bug-reports?ticket=' || NEW.id::TEXT,
    jsonb_build_object('ticket_number', NEW.ticket_number, 'status', NEW.status)
  );

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_qa_ticket_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_title TEXT;
  v_message TEXT;
  v_reward_message TEXT;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    v_title := public.lifecycle_notification_title_for_qa(NEW.status);
    v_reward_message := CASE
      WHEN COALESCE(NEW.reward_xp, 0) > 0 OR COALESCE(NEW.reward_credits, 0) > 0
        THEN ' Награда: '
          || CASE WHEN COALESCE(NEW.reward_xp, 0) > 0 THEN '+' || NEW.reward_xp::TEXT || ' XP' ELSE '' END
          || CASE
            WHEN COALESCE(NEW.reward_xp, 0) > 0 AND COALESCE(NEW.reward_credits, 0) > 0 THEN ', '
            ELSE ''
          END
          || CASE WHEN COALESCE(NEW.reward_credits, 0) > 0 THEN '+' || NEW.reward_credits::TEXT || ' монет' ELSE '' END
      ELSE ''
    END;

    v_message := CASE NEW.status
      WHEN 'confirmed' THEN 'Команда подтвердила баг.' || v_reward_message
      WHEN 'triaged' THEN 'Баг принят в план и получил приоритет.'
      WHEN 'in_progress' THEN 'Команда уже работает над исправлением.'
      WHEN 'fixed' THEN 'Исправление готово. Проверьте результат на своей стороне.'
      WHEN 'duplicate' THEN 'Репорт помечен как дубликат существующей задачи.'
      WHEN 'wont_fix' THEN 'Команда не планирует исправление по текущему репорту.'
      WHEN 'closed' THEN 'Репорт закрыт.'
      ELSE 'Статус баг-репорта обновлён.'
    END;

    PERFORM public.create_qa_ticket_event(
      NEW.id,
      'status_changed',
      v_title,
      COALESCE(NULLIF(NEW.resolution_notes, ''), v_message),
      OLD.status,
      NEW.status,
      auth.uid(),
      jsonb_build_object(
        'ticket_number', NEW.ticket_number,
        'reward_xp', COALESCE(NEW.reward_xp, 0),
        'reward_credits', COALESCE(NEW.reward_credits, 0)
      )
    );

    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
    VALUES (
      NEW.reporter_id,
      public.lifecycle_notification_type_for_qa(NEW.status),
      v_title,
      COALESCE(NULLIF(NEW.resolution_notes, ''), v_message),
      auth.uid(),
      'qa_ticket',
      NEW.id,
      '/bug-reports?ticket=' || NEW.id::TEXT,
      jsonb_build_object(
        'ticket_number', NEW.ticket_number,
        'status', NEW.status,
        'reward_xp', COALESCE(NEW.reward_xp, 0),
        'reward_credits', COALESCE(NEW.reward_credits, 0)
      )
    );
  END IF;

  IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to AND NEW.assigned_to IS NOT NULL THEN
    PERFORM public.create_qa_ticket_event(
      NEW.id,
      'assigned',
      'Репорт назначен исполнителю',
      'У бага появился ответственный исполнитель.',
      NULL,
      NEW.status,
      auth.uid(),
      jsonb_build_object('assigned_to', NEW.assigned_to)
    );
  END IF;

  IF (COALESCE(OLD.reward_xp, 0) <> COALESCE(NEW.reward_xp, 0) OR COALESCE(OLD.reward_credits, 0) <> COALESCE(NEW.reward_credits, 0))
    AND (COALESCE(NEW.reward_xp, 0) > 0 OR COALESCE(NEW.reward_credits, 0) > 0)
  THEN
    PERFORM public.create_qa_ticket_event(
      NEW.id,
      'reward_granted',
      'Награда начислена',
      'Репорт принёс награду: '
        || CASE WHEN COALESCE(NEW.reward_xp, 0) > 0 THEN '+' || NEW.reward_xp::TEXT || ' XP' ELSE '' END
        || CASE
          WHEN COALESCE(NEW.reward_xp, 0) > 0 AND COALESCE(NEW.reward_credits, 0) > 0 THEN ', '
          ELSE ''
        END
        || CASE WHEN COALESCE(NEW.reward_credits, 0) > 0 THEN '+' || NEW.reward_credits::TEXT || ' монет' ELSE '' END,
      NULL,
      NEW.status,
      auth.uid(),
      jsonb_build_object('reward_xp', COALESCE(NEW.reward_xp, 0), 'reward_credits', COALESCE(NEW.reward_credits, 0))
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_qa_ticket_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket RECORD;
BEGIN
  IF COALESCE(NEW.is_system, false) THEN
    RETURN NEW;
  END IF;

  SELECT id, reporter_id, ticket_number
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
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS support_ticket_created_lifecycle_trigger ON public.support_tickets;
CREATE TRIGGER support_ticket_created_lifecycle_trigger
AFTER INSERT ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.notify_support_ticket_created();

DROP TRIGGER IF EXISTS support_ticket_updated_lifecycle_trigger ON public.support_tickets;
CREATE TRIGGER support_ticket_updated_lifecycle_trigger
AFTER UPDATE ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.notify_support_ticket_updates();

DROP TRIGGER IF EXISTS support_ticket_message_lifecycle_trigger ON public.ticket_messages;
CREATE TRIGGER support_ticket_message_lifecycle_trigger
AFTER INSERT ON public.ticket_messages
FOR EACH ROW
EXECUTE FUNCTION public.notify_support_ticket_message();

DROP TRIGGER IF EXISTS qa_ticket_created_lifecycle_trigger ON public.qa_tickets;
CREATE TRIGGER qa_ticket_created_lifecycle_trigger
AFTER INSERT ON public.qa_tickets
FOR EACH ROW
EXECUTE FUNCTION public.notify_qa_ticket_created();

DROP TRIGGER IF EXISTS qa_ticket_updated_lifecycle_trigger ON public.qa_tickets;
CREATE TRIGGER qa_ticket_updated_lifecycle_trigger
AFTER UPDATE ON public.qa_tickets
FOR EACH ROW
EXECUTE FUNCTION public.notify_qa_ticket_updates();

DROP TRIGGER IF EXISTS qa_ticket_comment_lifecycle_trigger ON public.qa_comments;
CREATE TRIGGER qa_ticket_comment_lifecycle_trigger
AFTER INSERT ON public.qa_comments
FOR EACH ROW
EXECUTE FUNCTION public.notify_qa_ticket_comment();

DROP TRIGGER IF EXISTS on_ticket_message_staff_reply ON public.ticket_messages;
DROP TRIGGER IF EXISTS on_ticket_status_change ON public.support_tickets;

CREATE OR REPLACE FUNCTION public.resolve_qa_ticket(
  p_ticket_id UUID,
  p_status TEXT,
  p_notes TEXT DEFAULT NULL,
  p_reward_xp INTEGER DEFAULT 0,
  p_reward_credits INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_admin_id UUID;
  v_reporter_id UUID;
  v_old_status TEXT;
  v_bounty_id UUID;
  v_severity TEXT;
  v_existing_reward_xp INTEGER;
  v_existing_reward_credits INTEGER;
  v_bounty RECORD;
  v_final_xp INTEGER;
  v_final_credits INTEGER;
  v_rep INTEGER;
  v_tier RECORD;
  v_rewards_config JSONB;
  v_should_grant_reward BOOLEAN;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT reporter_id, status, bounty_id, severity, COALESCE(reward_xp, 0), COALESCE(reward_credits, 0)
    INTO v_reporter_id, v_old_status, v_bounty_id, v_severity, v_existing_reward_xp, v_existing_reward_credits
  FROM public.qa_tickets
  WHERE id = p_ticket_id;

  IF v_reporter_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ticket not found');
  END IF;

  v_final_xp := p_reward_xp;
  v_final_credits := p_reward_credits;

  IF v_bounty_id IS NOT NULL AND (v_final_xp = 0 AND v_final_credits = 0) THEN
    SELECT reward_xp, reward_credits, is_active, claimed_count, max_claims
      INTO v_bounty
    FROM public.qa_bounties
    WHERE id = v_bounty_id;

    IF v_bounty IS NOT NULL AND v_bounty.is_active AND v_bounty.claimed_count < v_bounty.max_claims THEN
      v_final_xp := v_bounty.reward_xp;
      v_final_credits := v_bounty.reward_credits;
    END IF;
  END IF;

  IF v_final_credits > 0 AND v_final_xp = 0 AND v_severity IS NOT NULL THEN
    SELECT value INTO v_rewards_config
    FROM public.qa_config
    WHERE key = 'rewards';

    IF v_rewards_config IS NOT NULL THEN
      v_final_xp := COALESCE((v_rewards_config->>(v_severity || '_xp'))::INTEGER, 0);
    END IF;
  END IF;

  v_should_grant_reward :=
    p_status = 'confirmed'
    AND COALESCE(v_existing_reward_xp, 0) = 0
    AND COALESCE(v_existing_reward_credits, 0) = 0
    AND (v_final_xp > 0 OR v_final_credits > 0);

  UPDATE public.qa_tickets
  SET status = p_status,
      resolution_notes = COALESCE(p_notes, resolution_notes),
      resolved_by = CASE
        WHEN p_status IN ('fixed', 'wont_fix', 'duplicate', 'closed') THEN v_admin_id
        ELSE resolved_by
      END,
      resolved_at = CASE
        WHEN p_status IN ('fixed', 'wont_fix', 'duplicate', 'closed') THEN now()
        ELSE resolved_at
      END,
      reward_xp = CASE
        WHEN v_should_grant_reward THEN v_final_xp
        ELSE reward_xp
      END,
      reward_credits = CASE
        WHEN v_should_grant_reward THEN v_final_credits
        ELSE reward_credits
      END
  WHERE id = p_ticket_id;

  IF v_should_grant_reward AND NOT public.is_user_blocked(v_reporter_id) THEN
    INSERT INTO public.qa_tester_stats (user_id, xp_earned, credits_earned)
    VALUES (v_reporter_id, v_final_xp, v_final_credits)
    ON CONFLICT (user_id) DO UPDATE SET
      xp_earned = qa_tester_stats.xp_earned + v_final_xp,
      credits_earned = qa_tester_stats.credits_earned + v_final_credits;

    IF v_final_xp > 0 THEN
      v_rep := LEAST(v_final_xp / 2, 10);

      INSERT INTO public.forum_user_stats (
        user_id,
        xp_total,
        xp_social,
        xp_daily_earned,
        xp_daily_date,
        reputation_score,
        last_activity_date,
        updated_at
      )
      VALUES (
        v_reporter_id,
        v_final_xp,
        v_final_xp,
        v_final_xp,
        CURRENT_DATE,
        v_rep,
        CURRENT_DATE,
        now()
      )
      ON CONFLICT (user_id) DO UPDATE SET
        xp_total = COALESCE(forum_user_stats.xp_total, 0) + v_final_xp,
        xp_social = COALESCE(forum_user_stats.xp_social, 0) + v_final_xp,
        xp_daily_earned = COALESCE(forum_user_stats.xp_daily_earned, 0) + v_final_xp,
        xp_daily_date = CURRENT_DATE,
        reputation_score = COALESCE(forum_user_stats.reputation_score, 0) + v_rep,
        last_activity_date = CURRENT_DATE,
        updated_at = now();

      SELECT *
        INTO v_tier
      FROM public.reputation_tiers
      WHERE min_xp <= (
        SELECT COALESCE(xp_total, 0)
        FROM public.forum_user_stats
        WHERE user_id = v_reporter_id
      )
      ORDER BY level DESC
      LIMIT 1;

      IF v_tier IS NOT NULL THEN
        UPDATE public.forum_user_stats
        SET tier = v_tier.key,
            vote_weight = v_tier.vote_weight,
            trust_level = v_tier.level
        WHERE user_id = v_reporter_id;
      END IF;

      INSERT INTO public.reputation_events (
        user_id,
        event_type,
        xp_delta,
        reputation_delta,
        category,
        source_type,
        source_id,
        metadata
      )
      VALUES (
        v_reporter_id,
        'qa_report_confirmed',
        v_final_xp,
        v_rep,
        'social',
        'qa_ticket',
        p_ticket_id,
        jsonb_build_object('xp_custom', v_final_xp, 'bounty_id', v_bounty_id)
      );
    END IF;

    IF v_final_credits > 0 THEN
      UPDATE public.profiles
      SET balance = balance + v_final_credits
      WHERE user_id = v_reporter_id;

      INSERT INTO public.balance_transactions (
        user_id,
        amount,
        type,
        description,
        reference_type,
        reference_id
      )
      VALUES (
        v_reporter_id,
        v_final_credits,
        'qa_reward',
        'Награда за подтверждённый баг #' || LEFT(p_ticket_id::TEXT, 8),
        'qa_ticket',
        p_ticket_id
      );
    END IF;

    IF v_bounty_id IS NOT NULL THEN
      UPDATE public.qa_bounties
      SET claimed_count = claimed_count + 1
      WHERE id = v_bounty_id;

      UPDATE public.qa_bounties
      SET is_active = false
      WHERE id = v_bounty_id
        AND claimed_count >= max_claims;
    END IF;
  END IF;

  IF p_status = 'confirmed' AND v_old_status IS DISTINCT FROM 'confirmed' THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_confirmed)
    VALUES (v_reporter_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET
      reports_confirmed = qa_tester_stats.reports_confirmed + 1;
  ELSIF p_status IN ('wont_fix', 'duplicate', 'closed')
    AND COALESCE(v_old_status, '') NOT IN ('confirmed', 'triaged', 'in_progress', 'fixed', 'wont_fix', 'duplicate', 'closed')
  THEN
    INSERT INTO public.qa_tester_stats (user_id, reports_rejected)
    VALUES (v_reporter_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET
      reports_rejected = qa_tester_stats.reports_rejected + 1;
  END IF;

  PERFORM public.qa_update_tester_tier(v_reporter_id);

  INSERT INTO public.qa_comments (ticket_id, user_id, message, is_staff, is_system)
  VALUES (
    p_ticket_id,
    v_admin_id,
    CASE p_status
      WHEN 'confirmed' THEN 'Баг подтверждён. ' || COALESCE(p_notes, '')
      WHEN 'triaged' THEN 'Баг принят в план. ' || COALESCE(p_notes, '')
      WHEN 'in_progress' THEN 'Исправление началось. ' || COALESCE(p_notes, '')
      WHEN 'fixed' THEN 'Баг исправлен. ' || COALESCE(p_notes, '')
      WHEN 'wont_fix' THEN 'Не будет исправлено. ' || COALESCE(p_notes, '')
      WHEN 'duplicate' THEN 'Дубликат. ' || COALESCE(p_notes, '')
      WHEN 'closed' THEN 'Закрыт. ' || COALESCE(p_notes, '')
      ELSE 'Статус изменён на ' || p_status || '. ' || COALESCE(p_notes, '')
    END,
    true,
    true
  );

  RETURN jsonb_build_object(
    'success', true,
    'status', p_status,
    'reward_granted', v_should_grant_reward,
    'reward_xp', CASE WHEN v_should_grant_reward THEN v_final_xp ELSE v_existing_reward_xp END,
    'reward_credits', CASE WHEN v_should_grant_reward THEN v_final_credits ELSE v_existing_reward_credits END
  );
END;
$function$;
