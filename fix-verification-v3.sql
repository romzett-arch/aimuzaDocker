-- FIX: target_id is UUID, not TEXT — pass v_req_id directly (already UUID)

DROP FUNCTION IF EXISTS public.approve_verification(text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.approve_verification(
  _request_id TEXT,
  _admin_id TEXT,
  _action TEXT,
  _rejection_reason TEXT DEFAULT NULL,
  _admin_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req_id UUID := _request_id::uuid;
  v_adm_id UUID := _admin_id::uuid;
  v_request RECORD;
  v_type_label TEXT;
BEGIN
  IF NOT is_admin(v_adm_id) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  SELECT * INTO v_request
  FROM verification_requests
  WHERE id = v_req_id AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found or already processed';
  END IF;

  IF _action = 'approve' THEN
    UPDATE profiles SET
      is_verified = true,
      verified_at = now(),
      verified_by = v_adm_id,
      verification_type = v_request.type
    WHERE user_id = v_request.user_id;

    UPDATE verification_requests SET
      status = 'approved',
      reviewed_by = v_adm_id,
      reviewed_at = now()
    WHERE id = v_req_id;

    v_type_label := CASE v_request.type
      WHEN 'artist' THEN 'Автор'
      WHEN 'creator' THEN 'Создатель'
      WHEN 'label' THEN 'Лейбл'
      WHEN 'partner' THEN 'Партнёр'
      ELSE v_request.type
    END;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, v_adm_id,
      'verification_approved',
      'Верификация подтверждена',
      'Поздравляем! Ваш аккаунт получил статус ' || v_type_label || '.',
      'verification', v_req_id
    );

    RETURN jsonb_build_object('status', 'approved', 'type', v_request.type);

  ELSIF _action = 'reject' THEN
    UPDATE verification_requests SET
      status = 'rejected',
      reviewed_by = v_adm_id,
      reviewed_at = now(),
      rejection_reason = _rejection_reason
    WHERE id = v_req_id;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, v_adm_id,
      'verification_rejected',
      'Заявка на верификацию отклонена',
      CASE WHEN _rejection_reason IS NOT NULL
        THEN 'Причина: ' || _rejection_reason
        ELSE 'Ваша заявка была отклонена.'
      END,
      'verification', v_req_id
    );

    RETURN jsonb_build_object('status', 'rejected');
  ELSE
    RAISE EXCEPTION 'Invalid action: %', _action;
  END IF;
END;
$$;

SELECT 'OK: approve_verification fixed (target_id uuid)' AS result;
