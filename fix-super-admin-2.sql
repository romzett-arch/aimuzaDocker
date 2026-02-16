BEGIN;

-- 2. Назначить super_admin для romzett@mail.ru
UPDATE public.user_roles
SET role = 'super_admin'
WHERE user_id = 'a0000000-0000-0000-0000-000000000001';

-- 3. Защита: триггер запрещает менять/удалять роль super_admin
CREATE OR REPLACE FUNCTION public.protect_super_admin_role()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.role::text = 'super_admin' THEN
    RAISE EXCEPTION 'Cannot delete super_admin role. Protected.';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.role::text = 'super_admin' AND NEW.role::text != 'super_admin' THEN
    RAISE EXCEPTION 'Cannot demote super_admin. Protected.';
  END IF;
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role::text = 'super_admin' THEN
    IF NEW.user_id != 'a0000000-0000-0000-0000-000000000001' THEN
      RAISE EXCEPTION 'Cannot assign super_admin to other users. Reserved.';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protect_super_admin ON public.user_roles;
CREATE TRIGGER protect_super_admin
  BEFORE INSERT OR UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION public.protect_super_admin_role();

-- 4. Функция is_super_admin
CREATE OR REPLACE FUNCTION public.is_super_admin(_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role::text = 'super_admin'
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMIT;
