-- Recreate account block RPCs with the parameter contract used by the frontend/API.
-- Older databases can still have block_user(p_user_id, p_reason, p_blocked_by, p_duration),
-- which makes the current named-argument call a no-op through the custom RPC compatibility path.

DROP FUNCTION IF EXISTS public.block_user(UUID, TEXT, UUID, TEXT);
DROP FUNCTION IF EXISTS public.block_user(UUID, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.unblock_user(UUID);

CREATE OR REPLACE FUNCTION public.block_user(
  _target_user_id UUID,
  _reason TEXT,
  _expires_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_block_id UUID;
  v_blocker_id UUID;
BEGIN
  v_blocker_id := auth.uid();

  IF v_blocker_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT (public.is_admin(v_blocker_id) OR public.has_permission(v_blocker_id, 'users')) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  IF public.is_super_admin(_target_user_id) THEN
    RAISE EXCEPTION 'cannot_block_super_admin';
  END IF;

  IF _target_user_id = v_blocker_id THEN
    RAISE EXCEPTION 'cannot_block_self';
  END IF;

  UPDATE public.user_blocks
  SET
    is_active = false,
    unblocked_at = now(),
    unblocked_by = v_blocker_id
  WHERE user_id = _target_user_id
    AND is_active = true;

  INSERT INTO public.user_blocks (user_id, blocked_by, reason, expires_at, is_active, blocked_at)
  VALUES (_target_user_id, v_blocker_id, COALESCE(NULLIF(_reason, ''), 'Без причины'), _expires_at, true, now())
  RETURNING id INTO v_block_id;

  UPDATE public.profiles
  SET
    is_blocked = true,
    blocked_at = now(),
    blocked_reason = COALESCE(NULLIF(_reason, ''), 'Без причины'),
    blocked_by = v_blocker_id
  WHERE user_id = _target_user_id;

  INSERT INTO public.notifications (user_id, type, title, message, actor_id)
  VALUES (
    _target_user_id,
    'system',
    'Аккаунт заблокирован',
    'Ваш аккаунт был заблокирован. Причина: ' || COALESCE(NULLIF(_reason, ''), 'Без причины') ||
      CASE
        WHEN _expires_at IS NOT NULL THEN '. Срок до: ' || to_char(_expires_at, 'DD.MM.YYYY HH24:MI')
        ELSE '. Срок: бессрочно'
      END,
    v_blocker_id
  );

  INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
  VALUES (
    _target_user_id,
    'blocked',
    v_blocker_id,
    COALESCE(NULLIF(_reason, ''), 'Без причины'),
    jsonb_build_object('expires_at', _expires_at, 'block_id', v_block_id)
  );

  RETURN v_block_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.unblock_user(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unblocker_id UUID;
  v_updated_count INTEGER;
BEGIN
  v_unblocker_id := auth.uid();

  IF v_unblocker_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT (public.is_admin(v_unblocker_id) OR public.has_permission(v_unblocker_id, 'users')) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  UPDATE public.user_blocks
  SET
    is_active = false,
    unblocked_at = now(),
    unblocked_by = v_unblocker_id
  WHERE user_id = _target_user_id
    AND is_active = true;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  IF v_updated_count > 0 THEN
    UPDATE public.profiles
    SET
      is_blocked = false,
      blocked_at = NULL,
      blocked_reason = NULL,
      blocked_by = NULL
    WHERE user_id = _target_user_id;

    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    VALUES (
      _target_user_id,
      'system',
      'Аккаунт разблокирован',
      'Ваш аккаунт был разблокирован. Вы снова можете пользоваться всеми функциями платформы.',
      v_unblocker_id
    );

    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (_target_user_id, 'unblocked', v_unblocker_id, 'Разблокировка администратором');
  END IF;

  RETURN v_updated_count > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.block_user(UUID, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unblock_user(UUID) TO authenticated;
