-- Connect customer-support cases with product defects without merging their lifecycles.

ALTER TABLE public.support_tickets
  ADD COLUMN IF NOT EXISTS qa_ticket_id UUID;

ALTER TABLE public.qa_tickets
  ADD COLUMN IF NOT EXISTS source_support_ticket_id UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'support_tickets_qa_ticket_id_fkey'
  ) THEN
    ALTER TABLE public.support_tickets
      ADD CONSTRAINT support_tickets_qa_ticket_id_fkey
      FOREIGN KEY (qa_ticket_id) REFERENCES public.qa_tickets(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'qa_tickets_source_support_ticket_id_fkey'
  ) THEN
    ALTER TABLE public.qa_tickets
      ADD CONSTRAINT qa_tickets_source_support_ticket_id_fkey
      FOREIGN KEY (source_support_ticket_id) REFERENCES public.support_tickets(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_support_tickets_qa_ticket_unique
  ON public.support_tickets(qa_ticket_id)
  WHERE qa_ticket_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_qa_tickets_source_support_unique
  ON public.qa_tickets(source_support_ticket_id)
  WHERE source_support_ticket_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_qa_ticket_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_support_number TEXT;
  v_event_title TEXT;
  v_event_description TEXT;
  v_notification_title TEXT;
  v_notification_message TEXT;
BEGIN
  IF NEW.source_support_ticket_id IS NOT NULL THEN
    SELECT ticket_number INTO v_support_number
    FROM public.support_tickets
    WHERE id = NEW.source_support_ticket_id;
  END IF;

  v_event_title := CASE
    WHEN NEW.source_support_ticket_id IS NOT NULL THEN 'Дефект создан из обращения'
    ELSE 'Репорт отправлен'
  END;
  v_event_description := CASE
    WHEN NEW.source_support_ticket_id IS NOT NULL
      THEN 'Обращение ' || COALESCE(v_support_number, LEFT(NEW.source_support_ticket_id::TEXT, 8)) || ' передано в техническую очередь.'
    ELSE 'Репорт принят и ждёт первичной проверки команды.'
  END;
  v_notification_title := CASE
    WHEN NEW.source_support_ticket_id IS NOT NULL THEN 'Обращение передано в разработку'
    ELSE 'Баг-репорт принят'
  END;
  v_notification_message := CASE
    WHEN NEW.source_support_ticket_id IS NOT NULL
      THEN 'По тикету ' || COALESCE(v_support_number, LEFT(NEW.source_support_ticket_id::TEXT, 8))
        || ' создан дефект ' || COALESCE(NEW.ticket_number, LEFT(NEW.id::TEXT, 8)) || '. Его технический статус теперь можно отслеживать в баг-репортах.'
    ELSE 'Репорт ' || COALESCE(NEW.ticket_number, LEFT(NEW.id::TEXT, 8)) || ' создан и ждёт проверки.'
  END;

  PERFORM public.create_qa_ticket_event(
    NEW.id,
    'created',
    v_event_title,
    v_event_description,
    NULL,
    NEW.status,
    NEW.reporter_id,
    jsonb_build_object(
      'ticket_number', NEW.ticket_number,
      'severity', NEW.severity,
      'category', NEW.category,
      'source_support_ticket_id', NEW.source_support_ticket_id
    )
  );

  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id, link, metadata)
  VALUES (
    NEW.reporter_id,
    'qa_ticket_received',
    v_notification_title,
    v_notification_message,
    NULL,
    'qa_ticket',
    NEW.id,
    '/bug-reports?ticket=' || NEW.id::TEXT,
    jsonb_build_object(
      'ticket_number', NEW.ticket_number,
      'status', NEW.status,
      'source_support_ticket_id', NEW.source_support_ticket_id
    )
  );

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.promote_support_ticket_to_qa(
  p_support_ticket_id UUID,
  p_category TEXT DEFAULT 'other',
  p_severity TEXT DEFAULT 'minor'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_support public.support_tickets%ROWTYPE;
  v_qa public.qa_tickets%ROWTYPE;
  v_description TEXT;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  IF NOT (
    public.has_role(v_actor_id, 'moderator'::public.app_role)
    OR public.has_role(v_actor_id, 'admin'::public.app_role)
    OR public.has_role(v_actor_id, 'super_admin'::public.app_role)
  ) THEN
    RAISE EXCEPTION 'Требуются права сотрудника поддержки';
  END IF;

  IF p_category NOT IN ('frontend', 'backend', 'ai_model', 'audio', 'performance', 'security', 'ui', 'other') THEN
    RAISE EXCEPTION 'Некорректная категория дефекта';
  END IF;

  IF p_severity NOT IN ('cosmetic', 'minor', 'major', 'critical', 'blocker') THEN
    RAISE EXCEPTION 'Некорректная серьёзность дефекта';
  END IF;

  SELECT * INTO v_support
  FROM public.support_tickets
  WHERE id = p_support_ticket_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Обращение не найдено';
  END IF;

  IF v_support.qa_ticket_id IS NOT NULL THEN
    SELECT * INTO v_qa FROM public.qa_tickets WHERE id = v_support.qa_ticket_id;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'qa_ticket_id', v_qa.id,
        'qa_ticket_number', v_qa.ticket_number,
        'created', false
      );
    END IF;
  END IF;

  SELECT * INTO v_qa
  FROM public.qa_tickets
  WHERE source_support_ticket_id = v_support.id;

  IF FOUND THEN
    UPDATE public.support_tickets SET qa_ticket_id = v_qa.id, updated_at = now() WHERE id = v_support.id;
    RETURN jsonb_build_object(
      'qa_ticket_id', v_qa.id,
      'qa_ticket_number', v_qa.ticket_number,
      'created', false
    );
  END IF;

  SELECT LEFT(
    COALESCE(
      string_agg(
        CASE WHEN COALESCE(tm.is_staff_reply, tm.is_staff, false)
          THEN 'Поддержка: '
          ELSE 'Пользователь: '
        END || tm.message,
        E'\n\n' ORDER BY tm.created_at
      ),
      v_support.subject
    ),
    10000
  ) INTO v_description
  FROM public.ticket_messages tm
  WHERE tm.ticket_id = v_support.id;

  INSERT INTO public.qa_tickets (
    reporter_id,
    category,
    severity,
    status,
    title,
    description,
    screenshots,
    tags,
    metadata,
    source_support_ticket_id
  ) VALUES (
    v_support.user_id,
    p_category,
    p_severity,
    'new',
    LEFT(v_support.subject, 200),
    v_description,
    '[]'::jsonb,
    ARRAY['из-поддержки']::TEXT[],
    jsonb_build_object(
      'source', 'support_ticket',
      'support_ticket_id', v_support.id,
      'support_ticket_number', v_support.ticket_number,
      'promoted_by', v_actor_id
    ),
    v_support.id
  )
  RETURNING * INTO v_qa;

  UPDATE public.support_tickets
  SET qa_ticket_id = v_qa.id,
      updated_at = now()
  WHERE id = v_support.id;

  PERFORM public.create_support_ticket_event(
    v_support.id,
    'promoted_to_qa',
    'Передано в разработку',
    'Из обращения создан дефект ' || COALESCE(v_qa.ticket_number, LEFT(v_qa.id::TEXT, 8)) || '.',
    v_support.status,
    v_support.status,
    v_actor_id,
    jsonb_build_object('qa_ticket_id', v_qa.id, 'qa_ticket_number', v_qa.ticket_number)
  );

  RETURN jsonb_build_object(
    'qa_ticket_id', v_qa.id,
    'qa_ticket_number', v_qa.ticket_number,
    'created', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.promote_support_ticket_to_qa(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.promote_support_ticket_to_qa(UUID, TEXT, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.normalize_notification_copy()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_title TEXT;
  v_message TEXT;
BEGIN
  IF NEW.message IS NULL THEN
    RETURN NEW;
  END IF;

  v_title := lower(regexp_replace(NEW.title, '[[:space:][:punct:]]+', '', 'g'));
  v_message := lower(regexp_replace(NEW.message, '[[:space:][:punct:]]+', '', 'g'));

  IF v_title = v_message THEN
    NEW.message := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS normalize_notification_copy_trigger ON public.notifications;
CREATE TRIGGER normalize_notification_copy_trigger
BEFORE INSERT OR UPDATE OF title, message ON public.notifications
FOR EACH ROW EXECUTE FUNCTION public.normalize_notification_copy();
