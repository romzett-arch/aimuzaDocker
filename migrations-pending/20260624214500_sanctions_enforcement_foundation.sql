-- Unified sanctions status and first server-enforcement hardening layer.

DROP FUNCTION IF EXISTS public.get_user_block_info(UUID);

CREATE OR REPLACE FUNCTION public.get_user_block_info(_user_id UUID)
RETURNS TABLE(
  id UUID,
  reason TEXT,
  blocked_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  blocked_by_username TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  IF _user_id IS DISTINCT FROM v_caller_id
     AND NOT (
       public.is_admin(v_caller_id)
       OR public.is_super_admin(v_caller_id)
       OR public.has_permission(v_caller_id, 'users')
     ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ub.id,
    ub.reason,
    ub.blocked_at,
    ub.expires_at,
    p.username AS blocked_by_username
  FROM public.user_blocks ub
  LEFT JOIN public.profiles p ON p.user_id = ub.blocked_by
  WHERE ub.user_id = _user_id
    AND ub.is_active = true
    AND (ub.expires_at IS NULL OR ub.expires_at > now())
  ORDER BY ub.blocked_at DESC
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_sanction_status()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_block_id UUID;
  v_block_reason TEXT;
  v_blocked_at TIMESTAMPTZ;
  v_block_expires_at TIMESTAMPTZ;
  v_blocked_by_username TEXT;
  v_account_blocked BOOLEAN := false;
  v_forum_banned BOOLEAN := false;
  v_forum_muted BOOLEAN := false;
  v_forum_silenced BOOLEAN := false;
  v_forum_ban_reason TEXT;
  v_forum_ban_expires_at TIMESTAMPTZ;
  v_forum_mute_reason TEXT;
  v_forum_mute_expires_at TIMESTAMPTZ;
  v_forum_silence_reason TEXT;
  v_forum_silence_expires_at TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'authenticated', false,
      'account_blocked', false,
      'sanctions', jsonb_build_object(
        'account_block', NULL,
        'forum_ban', NULL,
        'forum_mute', NULL,
        'forum_silence', NULL
      ),
      'permissions', jsonb_build_object(
        'can_read_public', true,
        'can_write_platform', false,
        'can_upload_storage', false,
        'can_use_forum', false,
        'can_post_forum', false,
        'can_message', false
      )
    );
  END IF;

  SELECT
    ub.id,
    ub.reason,
    ub.blocked_at,
    ub.expires_at,
    p.username
  INTO
    v_block_id,
    v_block_reason,
    v_blocked_at,
    v_block_expires_at,
    v_blocked_by_username
  FROM public.user_blocks ub
  LEFT JOIN public.profiles p ON p.user_id = ub.blocked_by
  WHERE ub.user_id = v_user_id
    AND ub.is_active = true
    AND (ub.expires_at IS NULL OR ub.expires_at > now())
  ORDER BY ub.blocked_at DESC
  LIMIT 1;

  v_account_blocked := v_block_id IS NOT NULL;
  v_forum_banned := public.forum_user_is_banned(v_user_id);
  v_forum_muted := public.forum_user_is_muted(v_user_id);
  v_forum_silenced := public.forum_user_is_silenced(v_user_id);

  SELECT b.reason, b.expires_at
  INTO v_forum_ban_reason, v_forum_ban_expires_at
  FROM public.forum_user_bans b
  WHERE b.user_id = v_user_id
    AND b.ban_zone IN ('forum', 'account')
    AND public.forum_is_sanction_active(b.is_active, b.expires_at)
  ORDER BY b.created_at DESC
  LIMIT 1;

  SELECT b.reason, b.expires_at
  INTO v_forum_mute_reason, v_forum_mute_expires_at
  FROM public.forum_user_bans b
  WHERE b.user_id = v_user_id
    AND b.ban_zone = 'comments'
    AND public.forum_is_sanction_active(b.is_active, b.expires_at)
  ORDER BY b.created_at DESC
  LIMIT 1;

  SELECT w.reason, w.expires_at
  INTO v_forum_silence_reason, v_forum_silence_expires_at
  FROM public.forum_warnings w
  WHERE w.user_id = v_user_id
    AND COALESCE(w.is_active, true)
    AND w.severity = 'silence'
    AND (w.expires_at IS NULL OR w.expires_at > now())
  ORDER BY w.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'authenticated', true,
    'account_blocked', v_account_blocked,
    'sanctions', jsonb_build_object(
      'account_block', CASE WHEN v_account_blocked THEN jsonb_build_object(
        'id', v_block_id,
        'reason', v_block_reason,
        'blocked_at', v_blocked_at,
        'expires_at', v_block_expires_at,
        'blocked_by_username', v_blocked_by_username
      ) ELSE NULL END,
      'forum_ban', CASE WHEN v_forum_banned THEN jsonb_build_object(
        'reason', v_forum_ban_reason,
        'expires_at', v_forum_ban_expires_at
      ) ELSE NULL END,
      'forum_mute', CASE WHEN v_forum_muted THEN jsonb_build_object(
        'reason', v_forum_mute_reason,
        'expires_at', v_forum_mute_expires_at
      ) ELSE NULL END,
      'forum_silence', CASE WHEN v_forum_silenced THEN jsonb_build_object(
        'reason', v_forum_silence_reason,
        'expires_at', v_forum_silence_expires_at
      ) ELSE NULL END
    ),
    'permissions', jsonb_build_object(
      'can_read_public', true,
      'can_write_platform', NOT v_account_blocked,
      'can_upload_storage', NOT v_account_blocked,
      'can_use_forum', NOT v_account_blocked AND NOT v_forum_banned AND NOT v_forum_silenced,
      'can_post_forum', NOT v_account_blocked AND NOT v_forum_banned AND NOT v_forum_muted AND NOT v_forum_silenced,
      'can_message', NOT v_account_blocked
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_super_admin_forum_sanction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.is_active, true)
     AND public.is_super_admin(NEW.user_id) THEN
    RAISE EXCEPTION 'super_admin_sanction_forbidden';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_super_admin_forum_sanction ON public.forum_user_bans;
CREATE TRIGGER trg_prevent_super_admin_forum_sanction
  BEFORE INSERT OR UPDATE ON public.forum_user_bans
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_super_admin_forum_sanction();

GRANT EXECUTE ON FUNCTION public.get_my_sanction_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_block_info(UUID) TO authenticated;
