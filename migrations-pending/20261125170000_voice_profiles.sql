CREATE TABLE public.voice_profiles (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
  status text NOT NULL DEFAULT 'phrase_queued' CHECK (status IN (
    'phrase_queued', 'phrase_dispatching', 'phrase_pending', 'verification_required',
    'voice_queued', 'voice_dispatching', 'voice_pending', 'ready', 'failed'
  )),
  source_start numeric(7,2) NOT NULL,
  source_end numeric(7,2) NOT NULL CHECK (source_end > source_start),
  phrase text,
  phrase_task_id text,
  voice_task_id text,
  provider_voice_id text,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 4),
  error_message text,
  next_poll_at timestamptz,
  consented_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE INDEX voice_profiles_owner_idx ON public.voice_profiles (user_id, created_at DESC);
CREATE INDEX voice_profiles_worker_idx ON public.voice_profiles (next_poll_at)
  WHERE deleted_at IS NULL AND status IN (
    'phrase_queued', 'phrase_dispatching', 'phrase_pending', 'voice_queued', 'voice_dispatching', 'voice_pending'
  );

CREATE TABLE public.voice_profile_recordings (
  profile_id uuid NOT NULL REFERENCES public.voice_profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('source', 'verification')),
  data bytea NOT NULL CHECK (octet_length(data) <= 4194304),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (profile_id, kind)
);

CREATE INDEX voice_profile_recordings_expiry_idx ON public.voice_profile_recordings (expires_at);

ALTER TABLE public.voice_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voice_profile_recordings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.voice_profiles, public.voice_profile_recordings FROM PUBLIC, anon, authenticated;
