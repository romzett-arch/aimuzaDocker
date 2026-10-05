-- auth.users in the custom local/production API does not expose confirmed_at.
-- Keep the activation transition portable and limited to email_confirmed_at.
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

  IF v_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('activated', false, 'email_confirmed_at', v_confirmed_at);
  END IF;

  UPDATE auth.users
  SET email_confirmed_at = now(),
      updated_at = now()
  WHERE id = p_user_id
  RETURNING email_confirmed_at INTO v_confirmed_at;

  INSERT INTO public.admin_email_confirmation_audit (admin_user_id, target_user_id, activated_at)
  VALUES (auth.uid(), p_user_id, v_confirmed_at);

  RETURN jsonb_build_object('activated', true, 'email_confirmed_at', v_confirmed_at);
END;
$$;
