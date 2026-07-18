-- Reconcile the non-login author used for automatic voting summary posts.
-- The migration is intentionally idempotent: production migration history can
-- survive a database restore while this data row is absent from auth.users.
BEGIN;

ALTER TABLE auth.users DISABLE TRIGGER on_auth_user_created;
ALTER TABLE auth.users DISABLE TRIGGER trg_welcome_balance;

INSERT INTO auth.users(id, email, raw_user_meta_data)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  'system-voting@aimuza.local',
  '{"username":"Система AIMUZA","service_identity":true}'::jsonb
)
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    raw_user_meta_data = coalesce(auth.users.raw_user_meta_data, '{}'::jsonb)
      || EXCLUDED.raw_user_meta_data;

ALTER TABLE auth.users ENABLE TRIGGER on_auth_user_created;
ALTER TABLE auth.users ENABLE TRIGGER trg_welcome_balance;

INSERT INTO public.profiles(user_id, username, balance)
VALUES ('00000000-0000-0000-0000-000000000000', 'Система AIMUZA', 0)
ON CONFLICT (user_id) DO UPDATE
SET username = EXCLUDED.username;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id = '00000000-0000-0000-0000-000000000000'
  ) THEN
    RAISE EXCEPTION 'Voting system forum actor reconciliation failed';
  END IF;
END;
$$;

COMMIT;
