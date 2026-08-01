ALTER TABLE public.role_change_logs DROP CONSTRAINT IF EXISTS role_change_logs_action_check;
ALTER TABLE public.maintenance_whitelist
  ADD COLUMN IF NOT EXISTS granted_by uuid,
  ADD COLUMN IF NOT EXISTS reason text;
CREATE UNIQUE INDEX IF NOT EXISTS maintenance_whitelist_user_id_key
  ON public.maintenance_whitelist(user_id);
ALTER TABLE public.role_change_logs ADD CONSTRAINT role_change_logs_action_check
CHECK (action = ANY (ARRAY[
  'invited', 'accepted', 'declined', 'revoked', 'expired', 'assigned',
  'invitation_cancelled', 'blocked', 'unblocked', 'balance_changed',
  'user_deleted', 'impersonation_started', 'impersonation_ended',
  'profile_updated', 'track_deleted', 'moderation_sent_to_voting',
  'moderation_approved', 'moderation_rejected', 'distribution_approved',
  'distribution_rejected', 'deposit_approved', 'deposit_rejected',
  'setting_changed', 'contest_created', 'contest_updated', 'contest_deleted',
  'tariff_granted', 'tariff_revoked', 'xp_adjusted',
  'maintenance_access_granted', 'maintenance_access_revoked'
]));

CREATE OR REPLACE FUNCTION public.admin_set_maintenance_access(
  p_user_id uuid,
  p_grant boolean,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reason text := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Укажите причину изменения доступа'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id=p_user_id) THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  IF p_grant THEN
    INSERT INTO public.maintenance_whitelist (user_id, granted_by, reason)
    VALUES (p_user_id, v_actor_id, v_reason)
    ON CONFLICT (user_id) DO UPDATE SET granted_by=EXCLUDED.granted_by, reason=EXCLUDED.reason, created_at=now();
  ELSE
    DELETE FROM public.maintenance_whitelist WHERE user_id=p_user_id;
  END IF;

  INSERT INTO public.role_change_logs (user_id, changed_by, action, reason, metadata)
  VALUES (p_user_id, v_actor_id,
    CASE WHEN p_grant THEN 'maintenance_access_granted' ELSE 'maintenance_access_revoked' END,
    v_reason, jsonb_build_object('granted', p_grant));

  INSERT INTO public.notifications (user_id, actor_id, type, title, message, target_type, target_id, metadata)
  VALUES (p_user_id, v_actor_id, 'system',
    CASE WHEN p_grant THEN 'Доступ во время техработ разрешён' ELSE 'Доступ во время техработ отключён' END,
    'Причина: ' || v_reason, 'profile', p_user_id,
    jsonb_build_object('event', CASE WHEN p_grant THEN 'maintenance_access_granted' ELSE 'maintenance_access_revoked' END));

  RETURN jsonb_build_object('success', true, 'granted', p_grant);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_maintenance_access(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_maintenance_access(uuid, boolean, text) TO authenticated;
