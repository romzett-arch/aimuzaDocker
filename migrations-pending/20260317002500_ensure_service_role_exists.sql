-- Создаём service_role для standalone PostgreSQL окружений,
-- чтобы последующие RLS-политики с `TO service_role` не падали.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'service_role'
  ) THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$$;
