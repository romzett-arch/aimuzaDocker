-- Manual confirmation is deliberately limited to the authentication state.
-- It does not grant credits, roles, subscriptions, or any other entitlement.
CREATE TABLE IF NOT EXISTS public.admin_email_confirmation_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id UUID NOT NULL REFERENCES auth.users(id),
  target_user_id UUID NOT NULL REFERENCES auth.users(id),
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (target_user_id)
);
ALTER TABLE public.admin_email_confirmation_audit ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE public.admin_email_confirmation_audit TO authenticated;
CREATE POLICY "Admins read email confirmation audit"
  ON public.admin_email_confirmation_audit
  FOR SELECT USING (public.is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.get_admin_user_auth_status(p_user_ids UUID[] DEFAULT NULL)
RETURNS TABLE(user_id UUID, email TEXT, last_sign_in_at TIMESTAMPTZ, email_confirmed_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  RETURN QUERY
  SELECT u.id, u.email::TEXT, u.last_sign_in_at, u.email_confirmed_at
  FROM auth.users u
  WHERE p_user_ids IS NULL OR u.id = ANY(p_user_ids);
END;
$$;
REVOKE ALL ON FUNCTION public.get_admin_user_auth_status(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_user_auth_status(UUID[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_manually_confirm_email(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE v_confirmed_at TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT email_confirmed_at INTO v_confirmed_at
  FROM auth.users
  WHERE id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  -- A second click or a stale screen must not create a false audit record.
  IF v_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('activated', false, 'email_confirmed_at', v_confirmed_at);
  END IF;

  UPDATE auth.users
  SET email_confirmed_at = now(),
      confirmed_at = COALESCE(confirmed_at, now()),
      updated_at = now()
  WHERE id = p_user_id
  RETURNING email_confirmed_at INTO v_confirmed_at;

  INSERT INTO public.admin_email_confirmation_audit (admin_user_id, target_user_id, activated_at)
  VALUES (auth.uid(), p_user_id, v_confirmed_at);

  RETURN jsonb_build_object('activated', true, 'email_confirmed_at', v_confirmed_at);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_manually_confirm_email(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_manually_confirm_email(UUID) TO authenticated;
