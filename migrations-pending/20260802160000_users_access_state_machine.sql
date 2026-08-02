-- Transactional state machine for users, roles, verification and sanctions.
-- Additive reconciliation: legacy verification columns are preserved.

ALTER TABLE public.verification_requests
  ADD COLUMN IF NOT EXISTS request_type text,
  ADD COLUMN IF NOT EXISTS portfolio_links text[],
  ADD COLUMN IF NOT EXISTS tracks_count integer,
  ADD COLUMN IF NOT EXISTS followers_count integer,
  ADD COLUMN IF NOT EXISTS document_urls text[],
  ADD COLUMN IF NOT EXISTS reason text,
  ADD COLUMN IF NOT EXISTS admin_notes text;

UPDATE public.verification_requests
SET request_type = COALESCE(NULLIF(request_type, ''), NULLIF(type, ''), 'creator'),
    portfolio_links = COALESCE(
      portfolio_links,
      CASE WHEN jsonb_typeof(social_links) = 'array'
        THEN ARRAY(SELECT jsonb_array_elements_text(social_links))
        ELSE ARRAY[]::text[] END
    ),
    document_urls = COALESCE(
      document_urls,
      CASE WHEN jsonb_typeof(documents) = 'array'
        THEN ARRAY(SELECT jsonb_array_elements_text(documents))
        ELSE ARRAY[]::text[] END
    ),
    reason = COALESCE(reason, notes),
    tracks_count = COALESCE(tracks_count, 0),
    followers_count = COALESCE(followers_count, 0)
WHERE request_type IS NULL
   OR portfolio_links IS NULL
   OR document_urls IS NULL
   OR tracks_count IS NULL
   OR followers_count IS NULL
   OR reason IS NULL;

ALTER TABLE public.verification_requests
  ALTER COLUMN request_type SET DEFAULT 'creator',
  ALTER COLUMN request_type SET NOT NULL,
  ALTER COLUMN tracks_count SET DEFAULT 0,
  ALTER COLUMN followers_count SET DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'verification_requests_request_type_check') THEN
    ALTER TABLE public.verification_requests
      ADD CONSTRAINT verification_requests_request_type_check
      CHECK (request_type IN ('creator', 'label', 'partner')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'verification_requests_status_check') THEN
    ALTER TABLE public.verification_requests
      ADD CONSTRAINT verification_requests_status_check
      CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')) NOT VALID;
  END IF;
END $$;

UPDATE public.role_invitations
SET status = 'expired', responded_at = COALESCE(responded_at, now())
WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= now();

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_roles_one_role_per_user
  ON public.user_roles(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_role_invitations_one_pending_per_user
  ON public.role_invitations(user_id) WHERE status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS idx_role_invitation_permissions_unique
  ON public.role_invitation_permissions(invitation_id, category_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_moderator_permissions_unique
  ON public.moderator_permissions(user_id, category_id);
CREATE INDEX IF NOT EXISTS idx_verification_requests_status_created
  ON public.verification_requests(status, created_at);
CREATE INDEX IF NOT EXISTS idx_user_blocks_history
  ON public.user_blocks(created_at DESC);

CREATE OR REPLACE FUNCTION public.submit_verification_request(
  p_request_type text,
  p_real_name text DEFAULT NULL,
  p_portfolio_links text[] DEFAULT ARRAY[]::text[],
  p_reason text DEFAULT NULL
) RETURNS public.verification_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_request public.verification_requests;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_request_type NOT IN ('creator', 'label', 'partner') THEN
    RAISE EXCEPTION 'invalid_verification_type';
  END IF;
  IF COALESCE(array_length(p_portfolio_links, 1), 0) > 10 THEN
    RAISE EXCEPTION 'too_many_portfolio_links';
  END IF;
  IF EXISTS (SELECT 1 FROM public.verification_requests WHERE user_id = v_user_id AND status = 'pending') THEN
    RAISE EXCEPTION 'pending_verification_exists';
  END IF;

  INSERT INTO public.verification_requests (
    user_id, request_type, type, real_name, portfolio_links, social_links,
    reason, notes, tracks_count, followers_count, status
  ) VALUES (
    v_user_id, p_request_type, p_request_type, NULLIF(trim(p_real_name), ''),
    COALESCE(p_portfolio_links, ARRAY[]::text[]), to_jsonb(COALESCE(p_portfolio_links, ARRAY[]::text[])),
    NULLIF(trim(p_reason), ''), NULLIF(trim(p_reason), ''),
    (SELECT count(*)::integer FROM public.tracks WHERE user_id = v_user_id AND status = 'completed'),
    (SELECT count(*)::integer FROM public.user_follows WHERE following_id = v_user_id),
    'pending'
  ) RETURNING * INTO v_request;

  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_process_verification(
  p_request_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_request public.verification_requests;
  v_approved boolean;
BEGIN
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT public.is_admin(v_actor_id) THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  IF p_action NOT IN ('approve', 'reject') THEN RAISE EXCEPTION 'invalid_action'; END IF;
  IF p_action = 'reject' AND NULLIF(trim(p_rejection_reason), '') IS NULL THEN
    RAISE EXCEPTION 'rejection_reason_required';
  END IF;

  SELECT * INTO v_request
  FROM public.verification_requests
  WHERE id = p_request_id AND status = 'pending'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'verification_request_not_pending'; END IF;

  v_approved := p_action = 'approve';
  IF v_approved THEN
    UPDATE public.profiles
    SET is_verified = true,
        verified_at = now(),
        verified_by = v_actor_id,
        verification_type = v_request.request_type
    WHERE user_id = v_request.user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'profile_not_found'; END IF;
  END IF;

  UPDATE public.verification_requests
  SET status = CASE WHEN v_approved THEN 'approved' ELSE 'rejected' END,
      reviewed_by = v_actor_id,
      reviewed_at = now(),
      rejection_reason = CASE WHEN v_approved THEN NULL ELSE trim(p_rejection_reason) END,
      updated_at = now()
  WHERE id = p_request_id;

  INSERT INTO public.notifications(user_id, actor_id, type, title, message, target_type, target_id)
  VALUES (
    v_request.user_id, v_actor_id,
    CASE WHEN v_approved THEN 'verification_approved' ELSE 'verification_rejected' END,
    CASE WHEN v_approved THEN 'Верификация подтверждена' ELSE 'Заявка на верификацию отклонена' END,
    CASE WHEN v_approved
      THEN 'Ваш аккаунт получил статус верифицированного автора.'
      ELSE 'Заявка отклонена. Причина: ' || trim(p_rejection_reason) END,
    'verification', p_request_id
  );

  INSERT INTO public.role_change_logs(user_id, changed_by, action, reason, metadata)
  VALUES (v_request.user_id, v_actor_id,
    CASE WHEN v_approved THEN 'verification_approved' ELSE 'verification_rejected' END,
    CASE WHEN v_approved THEN NULL ELSE trim(p_rejection_reason) END,
    jsonb_build_object('request_id', p_request_id, 'request_type', v_request.request_type));

  RETURN jsonb_build_object('request_id', p_request_id, 'user_id', v_request.user_id, 'approved', v_approved);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_role_invitation(
  p_user_id uuid,
  p_role text,
  p_message text DEFAULT NULL,
  p_category_ids uuid[] DEFAULT ARRAY[]::uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role public.app_role;
  v_target_role public.app_role;
  v_invitation public.role_invitations;
BEGIN
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  v_actor_role := public.get_user_role(v_actor_id);
  IF v_actor_role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  IF p_role NOT IN ('moderator', 'admin') THEN RAISE EXCEPTION 'invalid_assignable_role'; END IF;
  IF v_actor_role = 'admin' AND p_role <> 'moderator' THEN RAISE EXCEPTION 'role_hierarchy_violation'; END IF;
  IF p_user_id = v_actor_id THEN RAISE EXCEPTION 'cannot_change_own_role'; END IF;

  PERFORM 1 FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'profile_not_found'; END IF;
  v_target_role := public.get_user_role(p_user_id);
  IF v_target_role = 'super_admin' OR (v_actor_role = 'admin' AND v_target_role = 'admin') THEN
    RAISE EXCEPTION 'role_hierarchy_violation';
  END IF;

  UPDATE public.role_invitations SET status = 'expired', responded_at = COALESCE(responded_at, now())
  WHERE user_id = p_user_id AND status = 'pending' AND expires_at <= now();
  IF EXISTS (SELECT 1 FROM public.role_invitations WHERE user_id = p_user_id AND status = 'pending') THEN
    RAISE EXCEPTION 'active_invitation_exists';
  END IF;

  INSERT INTO public.role_invitations(user_id, role, invited_by, message, expires_at)
  VALUES (p_user_id, p_role, v_actor_id, NULLIF(trim(p_message), ''), now() + interval '7 days')
  RETURNING * INTO v_invitation;

  IF p_role = 'moderator' AND COALESCE(array_length(p_category_ids, 1), 0) > 0 THEN
    INSERT INTO public.role_invitation_permissions(invitation_id, category_id)
    SELECT v_invitation.id, pc.id
    FROM public.permission_categories pc
    WHERE pc.id = ANY(p_category_ids) AND pc.is_active
    ON CONFLICT (invitation_id, category_id) DO NOTHING;
  END IF;

  INSERT INTO public.role_change_logs(user_id, changed_by, action, new_role, metadata)
  VALUES (p_user_id, v_actor_id, 'invited', p_role,
    jsonb_build_object('invitation_id', v_invitation.id, 'category_ids', COALESCE(p_category_ids, ARRAY[]::uuid[])));
  INSERT INTO public.notifications(user_id, actor_id, type, title, message, target_type, target_id, link)
  VALUES (p_user_id, v_actor_id, 'system', 'Приглашение на роль',
    COALESCE(NULLIF(trim(p_message), ''), 'Вам отправлено приглашение на роль «' || p_role || '».'),
    'role_invitation', v_invitation.id, '/profile');

  RETURN to_jsonb(v_invitation);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_cancel_role_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role public.app_role;
  v_invitation public.role_invitations;
BEGIN
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  v_actor_role := public.get_user_role(v_actor_id);
  IF v_actor_role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  SELECT * INTO v_invitation FROM public.role_invitations WHERE id = p_invitation_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_not_pending'; END IF;
  IF v_actor_role = 'admin' AND v_invitation.role <> 'moderator' THEN RAISE EXCEPTION 'role_hierarchy_violation'; END IF;
  UPDATE public.role_invitations SET status = 'cancelled', responded_at = now() WHERE id = p_invitation_id;
  INSERT INTO public.role_change_logs(user_id, changed_by, action, new_role, metadata)
  VALUES (v_invitation.user_id, v_actor_id, 'invitation_cancelled', v_invitation.role,
    jsonb_build_object('invitation_id', p_invitation_id));
  RETURN jsonb_build_object('invitation_id', p_invitation_id, 'user_id', v_invitation.user_id, 'cancelled', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_user_role(p_user_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role public.app_role;
  v_target_role public.app_role;
BEGIN
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  v_actor_role := public.get_user_role(v_actor_id);
  v_target_role := public.get_user_role(p_user_id);
  IF v_actor_role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  IF p_user_id = v_actor_id THEN RAISE EXCEPTION 'cannot_change_own_role'; END IF;
  IF v_target_role = 'super_admin' OR (v_actor_role = 'admin' AND v_target_role <> 'moderator') THEN
    RAISE EXCEPTION 'role_hierarchy_violation';
  END IF;
  IF v_target_role = 'user' THEN RAISE EXCEPTION 'role_not_found'; END IF;

  PERFORM 1 FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;
  DELETE FROM public.moderator_permissions WHERE user_id = p_user_id;
  DELETE FROM public.user_roles WHERE user_id = p_user_id;
  UPDATE public.profiles SET role = 'user', is_super_admin = false WHERE user_id = p_user_id;
  INSERT INTO public.role_change_logs(user_id, changed_by, action, old_role, reason)
  VALUES (p_user_id, v_actor_id, 'revoked', v_target_role, NULLIF(trim(p_reason), ''));
  INSERT INTO public.notifications(user_id, actor_id, type, title, message, target_type, target_id)
  VALUES (p_user_id, v_actor_id, 'system', 'Роль снята',
    CASE WHEN NULLIF(trim(p_reason), '') IS NULL THEN 'Ваша административная роль была снята.'
      ELSE 'Ваша административная роль была снята. Причина: ' || trim(p_reason) END,
    'role_revocation', p_user_id);
  RETURN jsonb_build_object('user_id', p_user_id, 'old_role', v_target_role, 'revoked', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_user_permission(
  p_user_id uuid,
  p_category_id uuid,
  p_granted boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role public.app_role;
  v_target_role public.app_role;
BEGIN
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  v_actor_role := public.get_user_role(v_actor_id);
  v_target_role := public.get_user_role(p_user_id);
  IF v_actor_role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  IF v_actor_role = 'admin' AND v_target_role <> 'moderator' THEN RAISE EXCEPTION 'role_hierarchy_violation'; END IF;
  IF v_target_role NOT IN ('moderator', 'admin', 'super_admin') THEN RAISE EXCEPTION 'role_not_eligible'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.permission_categories WHERE id = p_category_id AND is_active) THEN
    RAISE EXCEPTION 'permission_category_not_found';
  END IF;

  IF p_granted THEN
    INSERT INTO public.moderator_permissions(user_id, category_id, granted_by)
    VALUES (p_user_id, p_category_id, v_actor_id)
    ON CONFLICT (user_id, category_id) DO NOTHING;
  ELSE
    DELETE FROM public.moderator_permissions WHERE user_id = p_user_id AND category_id = p_category_id;
  END IF;
  INSERT INTO public.role_change_logs(user_id, changed_by, action, metadata)
  VALUES (p_user_id, v_actor_id, CASE WHEN p_granted THEN 'permission_granted' ELSE 'permission_revoked' END,
    jsonb_build_object('category_id', p_category_id));
  RETURN jsonb_build_object('user_id', p_user_id, 'category_id', p_category_id, 'granted', p_granted);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reconcile_expired_blocks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN RAISE EXCEPTION 'insufficient_permissions'; END IF;
  WITH expired AS (
    UPDATE public.user_blocks
    SET is_active = false, unblocked_at = COALESCE(unblocked_at, now())
    WHERE is_active AND expires_at IS NOT NULL AND expires_at <= now()
    RETURNING user_id
  ), affected AS (SELECT DISTINCT user_id FROM expired)
  UPDATE public.profiles p
  SET is_blocked = false, blocked_at = NULL, blocked_reason = NULL, blocked_by = NULL
  FROM affected a
  WHERE p.user_id = a.user_id
    AND NOT EXISTS (SELECT 1 FROM public.user_blocks b WHERE b.user_id = a.user_id AND b.is_active AND (b.expires_at IS NULL OR b.expires_at > now()));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_verification_request(text, text, text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_process_verification(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_create_role_invitation(uuid, text, text, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_cancel_role_invitation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_revoke_user_role(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_user_permission(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reconcile_expired_blocks() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.submit_verification_request(text, text, text[], text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_process_verification(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_role_invitation(uuid, text, text, uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_cancel_role_invitation(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_user_role(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_user_permission(uuid, uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_reconcile_expired_blocks() TO authenticated, service_role;
