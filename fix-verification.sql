-- ═══════════════════════════════════════════════════════════
-- FIX 1: UNIQUE constraint — prevent duplicate pending requests
-- ═══════════════════════════════════════════════════════════
CREATE UNIQUE INDEX IF NOT EXISTS idx_verification_requests_one_pending
  ON public.verification_requests (user_id)
  WHERE status = 'pending';

-- ═══════════════════════════════════════════════════════════
-- FIX 2: FK on user_id (if not exists)
-- ═══════════════════════════════════════════════════════════
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'verification_requests_user_id_fkey'
  ) THEN
    ALTER TABLE public.verification_requests
      ADD CONSTRAINT verification_requests_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════
-- FIX 3: Replace inline admin check in RLS with is_admin()
-- ═══════════════════════════════════════════════════════════
DROP POLICY IF EXISTS "Admins can manage verification requests" ON public.verification_requests;
CREATE POLICY "Admins can manage verification requests"
  ON public.verification_requests
  FOR ALL
  USING (public.is_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- FIX 4: Add UPDATE policy for users (for future edit functionality)
-- ═══════════════════════════════════════════════════════════
DROP POLICY IF EXISTS "Users can update own pending requests" ON public.verification_requests;
CREATE POLICY "Users can update own pending requests"
  ON public.verification_requests
  FOR UPDATE
  USING (auth.uid() = user_id AND status = 'pending')
  WITH CHECK (auth.uid() = user_id AND status = 'pending');

-- ═══════════════════════════════════════════════════════════
-- FIX 5: Atomic approve_verification RPC function
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
  -- Check admin permission
  IF NOT is_admin(_admin_id) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  -- Get and lock the request
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
      verification_type = v_request.request_type
    WHERE user_id = v_request.user_id;

    -- Update request
    UPDATE verification_requests SET
      status = 'approved',
      reviewed_by = _admin_id,
      reviewed_at = now(),
      admin_notes = _admin_notes
    WHERE id = _request_id;

    -- Notification
    v_type_label := CASE v_request.request_type
      WHEN 'creator' THEN 'Создатель'
      WHEN 'label' THEN 'Лейбл'
      WHEN 'partner' THEN 'Партнёр'
      ELSE v_request.request_type
    END;

    INSERT INTO notifications (user_id, actor_id, type, title, message, target_type, target_id)
    VALUES (
      v_request.user_id, _admin_id,
      'verification_approved',
      '✓ Верификация подтверждена',
      'Поздравляем! Ваш аккаунт получил статус "' || v_type_label || '". Теперь ваш профиль отмечен значком верификации.',
      'verification', _request_id::text
    );

    RETURN jsonb_build_object('status', 'approved', 'type', v_request.request_type);

  ELSIF _action = 'reject' THEN
    UPDATE verification_requests SET
      status = 'rejected',
      reviewed_by = _admin_id,
      reviewed_at = now(),
      rejection_reason = _rejection_reason,
      admin_notes = _admin_notes
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

-- ═══════════════════════════════════════════════════════════
-- FIX 6: Revoke verification RPC function
-- ═══════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.revoke_verification(
  _user_id UUID,
  _admin_id UUID,
  _reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_admin(_admin_id) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE profiles SET
    is_verified = false,
    verified_at = NULL,
    verified_by = NULL,
    verification_type = NULL
  WHERE user_id = _user_id AND is_verified = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not verified';
  END IF;

  INSERT INTO notifications (user_id, actor_id, type, title, message)
  VALUES (
    _user_id, _admin_id,
    'system',
    'Верификация отозвана',
    'Ваш статус верификации был отозван.' ||
      CASE WHEN _reason IS NOT NULL THEN ' Причина: ' || _reason ELSE '' END
  );

  RETURN true;
END;
$$;

-- Verify
SELECT 'OK: verification fixes applied' AS result;
