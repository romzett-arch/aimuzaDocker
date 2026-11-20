CREATE TABLE IF NOT EXISTS public.max_chat_accounts (
  max_id text PRIMARY KEY,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  session_version integer NOT NULL
);
CREATE TABLE IF NOT EXISTS public.max_chat_challenges (
  link_hash text PRIMARY KEY,
  max_id text NOT NULL UNIQUE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  session_version integer,
  code_hash text,
  attempts integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL
);
ALTER TABLE public.max_chat_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.max_chat_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.max_chat_accounts, public.max_chat_challenges FROM PUBLIC, anon, authenticated;
