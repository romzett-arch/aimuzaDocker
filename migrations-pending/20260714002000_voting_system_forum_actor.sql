-- Stable non-login actor for automatic forum posts created by voting workers.
-- The auth triggers are disabled only for this insert so no welcome balance or
-- registration side effects are created for the service identity.
BEGIN;

ALTER TABLE auth.users DISABLE TRIGGER on_auth_user_created;
ALTER TABLE auth.users DISABLE TRIGGER trg_welcome_balance;

INSERT INTO auth.users(id, email, raw_user_meta_data)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  'system-voting@aimuza.local',
  '{"username":"Система AIMUZA","service_identity":true}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE auth.users ENABLE TRIGGER on_auth_user_created;
ALTER TABLE auth.users ENABLE TRIGGER trg_welcome_balance;

INSERT INTO public.profiles(user_id, username, balance)
VALUES ('00000000-0000-0000-0000-000000000000', 'Система AIMUZA', 0)
ON CONFLICT (user_id) DO UPDATE SET username = EXCLUDED.username;

COMMIT;
