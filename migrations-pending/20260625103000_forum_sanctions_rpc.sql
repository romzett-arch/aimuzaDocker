-- ==========================================================
-- FORUM SANCTIONS: admin RPC wrappers for issue/lift actions
-- ==========================================================

CREATE OR REPLACE FUNCTION public.forum_actor_can_moderate_sanctions(_actor_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    public.is_super_admin(_actor_id)
    OR public.is_admin(_actor_id)
    OR public.has_role(_actor_id, 'moderator'::public.app_role);
$$;

CREATE OR REPLACE FUNCTION public.forum_issue_sanction(
  p_target_user_id UUID,
  p_zone TEXT,
  p_hours INTEGER DEFAULT NULL,
  p_reason TEXT DEFAULT NULL,
  p_is_permanent BOOLEAN DEFAULT false
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_zone TEXT := lower(btrim(COALESCE(p_zone, '')));
  v_expires_at TIMESTAMPTZ := NULL;
  v_ban_id UUID;
  v_action TEXT;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'forum_auth_required';
  END IF;

  IF NOT public.forum_actor_can_moderate_sanctions(v_actor_id) THEN
    RAISE EXCEPTION 'forum_moderator_required';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'forum_target_required';
  END IF;

  IF v_zone NOT IN ('comments', 'forum', 'account') THEN
    RAISE EXCEPTION 'forum_invalid_sanction_zone';
  END IF;

  IF NOT COALESCE(p_is_permanent, false) THEN
    IF p_hours IS NULL OR p_hours <= 0 THEN
      RAISE EXCEPTION 'forum_positive_duration_required';
    END IF;

    v_expires_at := now() + make_interval(hours => p_hours);
  END IF;

  INSERT INTO public.forum_user_bans (
    user_id,
    ban_zone,
    reason,
    banned_by,
    expires_at,
    is_active
  )
  VALUES (
    p_target_user_id,
    v_zone,
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    v_actor_id,
    v_expires_at,
    true
  )
  RETURNING id INTO v_ban_id;

  v_action := CASE WHEN v_zone = 'comments' THEN 'mute_user' ELSE 'ban_user' END;

  INSERT INTO public.forum_mod_logs (
    moderator_id,
    action,
    target_type,
    target_id,
    details
  )
  VALUES (
    v_actor_id,
    v_action,
    'user',
    p_target_user_id,
    jsonb_build_object(
      'ban_id', v_ban_id,
      'zone', v_zone,
      'hours', p_hours,
      'reason', NULLIF(btrim(COALESCE(p_reason, '')), ''),
      'is_permanent', COALESCE(p_is_permanent, false)
    )
  );

  PERFORM public.forum_refresh_user_moderation_state(p_target_user_id);

  RETURN v_ban_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_lift_sanction(
  p_target_user_id UUID,
  p_zone TEXT DEFAULT NULL,
  p_ban_id UUID DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_zone TEXT := NULLIF(lower(btrim(COALESCE(p_zone, ''))), '');
  v_lifted_count INTEGER := 0;
  v_action TEXT;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'forum_auth_required';
  END IF;

  IF NOT public.forum_actor_can_moderate_sanctions(v_actor_id) THEN
    RAISE EXCEPTION 'forum_moderator_required';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'forum_target_required';
  END IF;

  IF v_zone IS NOT NULL AND v_zone NOT IN ('comments', 'forum', 'account') THEN
    RAISE EXCEPTION 'forum_invalid_sanction_zone';
  END IF;

  IF p_ban_id IS NOT NULL THEN
    UPDATE public.forum_user_bans
    SET is_active = false
    WHERE id = p_ban_id
      AND user_id = p_target_user_id
      AND is_active = true;
  ELSIF v_zone = 'forum' THEN
    UPDATE public.forum_user_bans
    SET is_active = false
    WHERE user_id = p_target_user_id
      AND ban_zone IN ('forum', 'account')
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > now());
  ELSE
    UPDATE public.forum_user_bans
    SET is_active = false
    WHERE user_id = p_target_user_id
      AND (v_zone IS NULL OR ban_zone = v_zone)
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > now());
  END IF;

  GET DIAGNOSTICS v_lifted_count = ROW_COUNT;

  IF v_zone = 'comments' THEN
    UPDATE public.forum_user_stats
    SET
      is_muted = false,
      muted_until = NULL,
      updated_at = now()
    WHERE user_id = p_target_user_id;
  END IF;

  v_action := CASE WHEN v_zone = 'comments' THEN 'unmute_user' ELSE 'unban_user' END;

  INSERT INTO public.forum_mod_logs (
    moderator_id,
    action,
    target_type,
    target_id,
    details
  )
  VALUES (
    v_actor_id,
    v_action,
    'user',
    p_target_user_id,
    jsonb_build_object(
      'ban_id', p_ban_id,
      'zone', v_zone,
      'lifted_count', v_lifted_count
    )
  );

  PERFORM public.forum_refresh_user_moderation_state(p_target_user_id);

  RETURN v_lifted_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.forum_issue_sanction(UUID, TEXT, INTEGER, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_lift_sanction(UUID, TEXT, UUID) TO authenticated;
