ALTER TABLE public.role_change_logs
DROP CONSTRAINT IF EXISTS role_change_logs_action_check;

ALTER TABLE public.role_change_logs
ADD CONSTRAINT role_change_logs_action_check
CHECK (action IN (
  'invited', 'accepted', 'declined', 'revoked', 'expired', 'assigned',
  'invitation_cancelled', 'permission_granted', 'permission_revoked',
  'verification_approved', 'verification_rejected',
  'blocked', 'unblocked', 'balance_changed', 'user_deleted',
  'impersonation_started', 'impersonation_ended', 'profile_updated', 'track_deleted',
  'moderation_sent_to_voting', 'moderation_approved', 'moderation_rejected',
  'distribution_approved', 'distribution_rejected', 'deposit_approved', 'deposit_rejected',
  'setting_changed', 'contest_created', 'contest_updated', 'contest_deleted',
  'tariff_granted', 'tariff_revoked', 'xp_adjusted',
  'maintenance_access_granted', 'maintenance_access_revoked'
));

CREATE OR REPLACE FUNCTION public.accept_role_invitation(_invitation_id uuid, _accept boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_invitation record;
  v_inviter_role public.app_role;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT ri.*,
    COALESCE((SELECT jsonb_agg(rip.category_id) FROM public.role_invitation_permissions rip WHERE rip.invitation_id=ri.id), '[]'::jsonb) AS permission_ids
  INTO v_invitation
  FROM public.role_invitations ri
  WHERE ri.id=_invitation_id AND ri.user_id=v_user_id AND ri.status='pending'
    AND (ri.expires_at IS NULL OR ri.expires_at>now())
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_not_found_or_expired'; END IF;
  IF v_invitation.role NOT IN ('moderator', 'admin') THEN RAISE EXCEPTION 'invalid_assignable_role'; END IF;
  IF public.get_user_role(v_user_id)='super_admin' THEN RAISE EXCEPTION 'cannot_change_super_admin_role'; END IF;

  v_inviter_role := public.get_user_role(v_invitation.invited_by);
  IF v_inviter_role NOT IN ('admin','super_admin')
    OR (v_invitation.role='admin' AND v_inviter_role<>'super_admin') THEN
    RAISE EXCEPTION 'inviter_no_longer_authorized';
  END IF;

  UPDATE public.role_invitations
  SET status=CASE WHEN _accept THEN 'accepted' ELSE 'declined' END, responded_at=now()
  WHERE id=_invitation_id;

  IF _accept THEN
    DELETE FROM public.moderator_permissions WHERE user_id=v_user_id;
    DELETE FROM public.user_roles WHERE user_id=v_user_id;
    INSERT INTO public.user_roles(user_id, role) VALUES(v_user_id, v_invitation.role::public.app_role);

    IF v_invitation.role='moderator' AND jsonb_array_length(v_invitation.permission_ids)>0 THEN
      INSERT INTO public.moderator_permissions(user_id, category_id, granted_by)
      SELECT v_user_id, j.category_id::uuid, v_invitation.invited_by
      FROM jsonb_array_elements_text(v_invitation.permission_ids) AS j(category_id)
      JOIN public.permission_categories pc ON pc.id=j.category_id::uuid AND pc.is_active
      ON CONFLICT (user_id, category_id) DO NOTHING;
    END IF;

    UPDATE public.profiles
    SET role=v_invitation.role, is_super_admin=false
    WHERE user_id=v_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'profile_not_found'; END IF;
  END IF;

  INSERT INTO public.role_change_logs(user_id, changed_by, action, new_role, metadata)
  VALUES(v_user_id, v_invitation.invited_by,
    CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
    CASE WHEN _accept THEN v_invitation.role ELSE NULL END,
    jsonb_build_object('invitation_id', _invitation_id, 'role', v_invitation.role));

  INSERT INTO public.notifications(user_id, type, title, message, target_type, target_id, actor_id)
  VALUES(v_invitation.invited_by,
    CASE WHEN _accept THEN 'role_accepted' ELSE 'role_declined' END,
    CASE WHEN _accept THEN 'Приглашение на роль принято' ELSE 'Приглашение на роль отклонено' END,
    CASE WHEN _accept THEN 'Пользователь принял приглашение и получил назначенную роль.' ELSE 'Пользователь отклонил приглашение на роль.' END,
    'role_invitation', _invitation_id, v_user_id);

  RETURN jsonb_build_object('accepted', _accept, 'role', v_invitation.role);
END;
$$;

REVOKE ALL ON FUNCTION public.accept_role_invitation(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_role_invitation(uuid, boolean) TO authenticated, service_role;
