CREATE TABLE auth.yandex_identities (
  subject text PRIMARY KEY,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE auth.yandex_flows (
  state_hash text PRIMARY KEY,
  binding_hash text NOT NULL,
  verifier text NOT NULL,
  destination text NOT NULL CHECK (destination IN ('site','studio','android')),
  link_user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  link_version integer,
  consent boolean NOT NULL DEFAULT false,
  profile jsonb,
  ticket_hash text UNIQUE,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);
CREATE INDEX yandex_flows_expiry ON auth.yandex_flows(expires_at);
REVOKE ALL ON auth.yandex_identities, auth.yandex_flows FROM PUBLIC, anon, authenticated;
