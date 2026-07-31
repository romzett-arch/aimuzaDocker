-- Extend the unified broadcast RPC with configurable popup delivery.
DROP FUNCTION IF EXISTS public.admin_send_mass_broadcast(uuid[], text[], text, text, text, text);

CREATE OR REPLACE FUNCTION public.admin_send_mass_broadcast(
  p_recipient_ids uuid[],
  p_channels text[],
  p_title text,
  p_content text,
  p_link text DEFAULT NULL,
  p_popup_mode text DEFAULT 'modal',
  p_popup_custom_display_mode text DEFAULT 'modal',
  p_popup_priority text DEFAULT 'info',
  p_popup_dismissible boolean DEFAULT true,
  p_popup_action_label text DEFAULT NULL,
  p_popup_cover_url text DEFAULT NULL,
  p_popup_expires_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_admin_id uuid := auth.uid();
  v_recipient_id uuid;
  v_conversation_id uuid;
  v_message_id uuid;
  v_recipient_ids uuid[];
  v_private_messages integer := 0;
  v_notifications integer := 0;
  v_popups integer := 0;
  v_popup_display_mode public.announcement_display_mode;
  v_popup_priority public.announcement_priority;
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin(v_admin_id) THEN
    RAISE EXCEPTION 'Недостаточно прав для массовой рассылки';
  END IF;

  IF btrim(COALESCE(p_title, '')) = '' OR btrim(COALESCE(p_content, '')) = '' THEN
    RAISE EXCEPTION 'Заголовок и текст обязательны';
  END IF;

  IF COALESCE(array_length(p_channels, 1), 0) = 0
     OR EXISTS (
       SELECT 1 FROM unnest(p_channels) channel
       WHERE channel NOT IN ('private_message', 'popup', 'notification')
     ) THEN
    RAISE EXCEPTION 'Передан неизвестный канал доставки';
  END IF;

  IF p_popup_mode NOT IN ('modal', 'banner', 'custom')
     OR p_popup_custom_display_mode NOT IN ('modal', 'banner')
     OR p_popup_priority NOT IN ('info', 'warning', 'critical') THEN
    RAISE EXCEPTION 'Некорректные настройки всплывающего уведомления';
  END IF;

  v_popup_display_mode := (
    CASE WHEN p_popup_mode = 'custom' THEN p_popup_custom_display_mode ELSE p_popup_mode END
  )::public.announcement_display_mode;
  v_popup_priority := (
    CASE WHEN p_popup_mode = 'custom' THEN p_popup_priority ELSE 'info' END
  )::public.announcement_priority;

  SELECT COALESCE(array_agg(DISTINCT p.user_id), ARRAY[]::uuid[])
  INTO v_recipient_ids
  FROM public.profiles p
  WHERE p.user_id = ANY(COALESCE(p_recipient_ids, ARRAY[]::uuid[]))
    AND p.user_id <> v_admin_id;

  IF 'notification' = ANY(p_channels) THEN
    INSERT INTO public.notifications (
      user_id, actor_id, type, title, message, link, target_type, metadata
    )
    SELECT
      recipient_id,
      v_admin_id,
      'admin_broadcast',
      btrim(p_title),
      btrim(p_content),
      NULLIF(btrim(COALESCE(p_link, '')), ''),
      'admin_broadcast',
      jsonb_build_object('channel', 'mass_notification')
    FROM unnest(v_recipient_ids) recipient_id;

    GET DIAGNOSTICS v_notifications = ROW_COUNT;
  END IF;

  IF 'private_message' = ANY(p_channels) THEN
    FOREACH v_recipient_id IN ARRAY v_recipient_ids
    LOOP
      SELECT c.id
      INTO v_conversation_id
      FROM public.conversations c
      JOIN public.conversation_participants admin_participant
        ON admin_participant.conversation_id = c.id
       AND admin_participant.user_id = v_admin_id
      JOIN public.conversation_participants user_participant
        ON user_participant.conversation_id = c.id
       AND user_participant.user_id = v_recipient_id
      WHERE c.type = 'admin_support'
      ORDER BY c.created_at DESC
      LIMIT 1;

      IF v_conversation_id IS NULL THEN
        INSERT INTO public.conversations (type, status, created_by)
        VALUES ('admin_support', 'active', v_admin_id)
        RETURNING id INTO v_conversation_id;

        INSERT INTO public.conversation_participants (conversation_id, user_id, role)
        VALUES
          (v_conversation_id, v_admin_id, 'admin'),
          (v_conversation_id, v_recipient_id, 'member');
      ELSE
        UPDATE public.conversations
        SET status = 'active', closed_by = NULL, closed_at = NULL
        WHERE id = v_conversation_id;

        UPDATE public.conversation_participants
        SET deleted_at = NULL, archived_at = NULL
        WHERE conversation_id = v_conversation_id;
      END IF;

      INSERT INTO public.messages (conversation_id, sender_id, content)
      VALUES (
        v_conversation_id,
        v_admin_id,
        btrim(p_title) || E'\n\n' || btrim(p_content)
      )
      RETURNING id INTO v_message_id;

      UPDATE public.conversations
      SET last_message_id = v_message_id,
          last_message_at = now(),
          updated_at = now()
      WHERE id = v_conversation_id;

      v_private_messages := v_private_messages + 1;
      v_conversation_id := NULL;
    END LOOP;
  END IF;

  IF 'popup' = ANY(p_channels) THEN
    INSERT INTO public.admin_announcements (
      title,
      content,
      announcement_type,
      display_mode,
      priority,
      is_dismissible,
      is_published,
      publish_at,
      expires_at,
      action_url,
      action_label,
      cover_url,
      created_by
    )
    VALUES (
      btrim(p_title),
      btrim(p_content),
      'news',
      v_popup_display_mode,
      v_popup_priority,
      CASE WHEN p_popup_mode = 'custom' THEN p_popup_dismissible ELSE true END,
      true,
      now(),
      CASE WHEN p_popup_mode = 'custom' THEN p_popup_expires_at ELSE NULL END,
      NULLIF(btrim(COALESCE(p_link, '')), ''),
      CASE
        WHEN NULLIF(btrim(COALESCE(p_link, '')), '') IS NULL THEN NULL
        WHEN p_popup_mode = 'custom' THEN COALESCE(NULLIF(btrim(p_popup_action_label), ''), 'Подробнее')
        ELSE 'Подробнее'
      END,
      CASE WHEN p_popup_mode = 'custom' THEN NULLIF(btrim(COALESCE(p_popup_cover_url, '')), '') ELSE NULL END,
      v_admin_id
    );
    v_popups := 1;
  END IF;

  RETURN jsonb_build_object(
    'private_messages', v_private_messages,
    'notifications', v_notifications,
    'popups', v_popups
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_send_mass_broadcast(
  uuid[], text[], text, text, text, text, text, text, boolean, text, text, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_send_mass_broadcast(
  uuid[], text[], text, text, text, text, text, text, boolean, text, text, timestamptz
) TO authenticated;

