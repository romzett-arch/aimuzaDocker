-- ═══════════════════════════════════════════════════════════
-- FIX approve_verification RPC — match REAL schema columns:
--   verification_requests: type (not request_type), rejection_reason, notes
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approve_verification(
  _request_id UUID,
  _admin_id UUID,
  _action TEXT, -- 'approve' or 'reject'
  _rejection_reason TEXT DEFAULT NULL,
  _admin_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request RECORD;
  v_type_label TEXT;
BEGIN
  IF NOT is_admin(_admin_id) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  -- Lock the request row
  SELECT * INTO v_request
  FROM verification_requests
  WHERE id = _request_id AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found or already processed';
  END IF;

  IF _action = 'approve' THEN
    -- Update profile
    UPDATE profiles SET
      is_verified = true,
      verified_at = now(),
      verified_by = _admin_id,
      verification_type = v_request.type
    WHERE user_id = v_request.user_id;

    -- Update request
    UPDATE verification_requests SET
      status = 'approved',
      reviewed_by = _admin_id,
      reviewed_at = now()
    WHERE id = _request_id;

    v_type_label := CASE v_request.type
      WHEN 'artist' THEN 'Автор'
      WHEN 'creator' THEN 'Создатель'
      WHEN 'label' THEN 'Лейбл'
      WHEN 'partner' THEN 'Партнёр'
      ELSE v_request.type
    END;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, _admin_id,
      'verification_approved',
      '✓ Верификация подтверждена',
      'Поздравляем! Ваш аккаунт получил статус "' || v_type_label || '". Теперь ваш профиль отмечен значком верификации.',
      'verification', _request_id::text
    );

    RETURN jsonb_build_object('status', 'approved', 'type', v_request.type);

  ELSIF _action = 'reject' THEN
    UPDATE verification_requests SET
      status = 'rejected',
      reviewed_by = _admin_id,
      reviewed_at = now(),
      rejection_reason = _rejection_reason
    WHERE id = _request_id;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, _admin_id,
      'verification_rejected',
      '✗ Заявка на верификацию отклонена',
      'К сожалению, ваша заявка на верификацию была отклонена.' ||
        CASE WHEN _rejection_reason IS NOT NULL THEN ' Причина: ' || _rejection_reason ELSE '' END,
      'verification', _request_id::text
    );

    RETURN jsonb_build_object('status', 'rejected');
  ELSE
    RAISE EXCEPTION 'Invalid action: %', _action;
  END IF;
END;
$$;

-- Reload PostgREST
NOTIFY pgrst, 'reload schema';

SELECT 'OK: approve_verification v2 applied' AS result;
