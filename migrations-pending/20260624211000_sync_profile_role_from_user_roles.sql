-- Keep legacy profile role flags in sync with the canonical user_roles table.

CREATE OR REPLACE FUNCTION public.sync_profile_role_from_user_roles(_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role public.app_role;
BEGIN
  SELECT ur.role
  INTO v_role
  FROM public.user_roles ur
  WHERE ur.user_id = _user_id
  ORDER BY CASE ur.role
    WHEN 'super_admin' THEN 1
    WHEN 'admin' THEN 2
    WHEN 'moderator' THEN 3
    ELSE 4
  END
  LIMIT 1;

  IF v_role IS NULL THEN
    UPDATE public.profiles
    SET role = 'user',
        is_super_admin = false,
        is_protected = false
    WHERE user_id = _user_id
      AND is_protected IS DISTINCT FROM true;
    RETURN;
  END IF;

  UPDATE public.profiles
  SET role = v_role::text,
      is_super_admin = (v_role = 'super_admin'::public.app_role),
      is_protected = (v_role = 'super_admin'::public.app_role)
  WHERE user_id = _user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_profile_role_from_user_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.sync_profile_role_from_user_roles(NEW.user_id);
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM public.sync_profile_role_from_user_roles(OLD.user_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_profile_role_from_user_roles ON public.user_roles;
CREATE TRIGGER trg_sync_profile_role_from_user_roles
AFTER INSERT OR UPDATE OR DELETE ON public.user_roles
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_profile_role_from_user_roles();

DO $$
DECLARE
  v_profile record;
BEGIN
  FOR v_profile IN
    SELECT p.user_id
    FROM public.profiles p
  LOOP
    PERFORM public.sync_profile_role_from_user_roles(v_profile.user_id);
  END LOOP;
END;
$$;
