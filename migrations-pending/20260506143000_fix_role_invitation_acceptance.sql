-- Fix role invitation acceptance.
-- Keep role assignment atomic and avoid stale roles/permissions after accepting admin/moderator invitations.

CREATE OR REPLACE FUNCTION public.accept_role_invitation(
  _invitation_id uuid,
  _accept boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_invitation record;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    BEGIN
      v_user_id := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_user_id := NULL;
    END;
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT
    ri.*,
    COALESCE(
      (
        SELECT jsonb_agg(rip.category_id)
        FROM public.role_invitation_permissions rip
        WHERE rip.invitation_id = ri.id
      ),
      '[]'::jsonb
    ) AS permission_ids
  INTO v_invitation
  FROM public.role_invitations ri
  WHERE ri.id = _invitation_id
    AND ri.user_id = v_user_id
    AND ri.status = 'pending'
    AND (ri.expires_at IS NULL OR ri.expires_at > now())
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found or expired';
  END IF;

  UPDATE public.role_invitations
  SET
    status = CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
    responded_at = now()
  WHERE id = _invitation_id;

  IF _accept THEN
    DELETE FROM public.moderator_permissions
    WHERE user_id = v_user_id;

    DELETE FROM public.user_roles
    WHERE user_id = v_user_id
      AND role <> 'super_admin';

    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_user_id, v_invitation.role::app_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    IF v_invitation.role = 'moderator' AND jsonb_array_length(v_invitation.permission_ids) > 0 THEN
      INSERT INTO public.moderator_permissions (user_id, category_id, granted_by)
      SELECT v_user_id, category_id::uuid, v_invitation.invited_by
      FROM jsonb_array_elements_text(v_invitation.permission_ids) AS category_id
      ON CONFLICT (user_id, category_id) DO NOTHING;
    END IF;

    UPDATE public.profiles
    SET role = v_invitation.role
    WHERE user_id = v_user_id;
  END IF;

  INSERT INTO public.role_change_logs (user_id, changed_by, action, new_role, metadata)
  VALUES (
    v_user_id,
    v_invitation.invited_by,
    CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
    CASE WHEN _accept THEN v_invitation.role::app_role ELSE NULL END,
    jsonb_build_object('invitation_id', _invitation_id, 'role', v_invitation.role)
  );

  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id, actor_id)
  VALUES (
    v_invitation.invited_by,
    CASE WHEN _accept THEN 'role_accepted' ELSE 'role_declined' END,
    CASE WHEN _accept
      THEN 'Приглашение на роль ' || v_invitation.role || ' принято'
      ELSE 'Приглашение на роль ' || v_invitation.role || ' отклонено'
    END,
    CASE WHEN _accept
      THEN 'Пользователь принял приглашение и получил назначенную роль'
      ELSE 'Пользователь отклонил приглашение на роль'
    END,
    'role_invitation',
    _invitation_id,
    v_user_id
  );

  RETURN jsonb_build_object(
    'accepted', _accept,
    'role', v_invitation.role
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_role_invitation(uuid, boolean) TO authenticated;
