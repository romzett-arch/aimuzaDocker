-- Reconcile legacy forum tables with the contracts used by the current frontend.
-- Some restored databases still contain the older poll/read schemas.

BEGIN;

ALTER TABLE public.forum_polls
  ADD COLUMN IF NOT EXISTS poll_type text,
  ADD COLUMN IF NOT EXISTS is_anonymous boolean,
  ADD COLUMN IF NOT EXISTS ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_closed boolean,
  ADD COLUMN IF NOT EXISTS created_by uuid,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_polls'
      AND column_name = 'allow_multiple'
  ) THEN
    UPDATE public.forum_polls
    SET poll_type = CASE WHEN allow_multiple THEN 'multiple' ELSE 'single' END
    WHERE poll_type IS NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_polls'
      AND column_name = 'anonymous'
  ) THEN
    UPDATE public.forum_polls
    SET is_anonymous = anonymous
    WHERE is_anonymous IS NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_polls'
      AND column_name = 'expires_at'
  ) THEN
    UPDATE public.forum_polls
    SET ends_at = expires_at
    WHERE ends_at IS NULL;
  END IF;
END;
$$;

UPDATE public.forum_polls p
SET created_by = t.user_id
FROM public.forum_topics t
WHERE t.id = p.topic_id
  AND p.created_by IS NULL;

UPDATE public.forum_polls
SET poll_type = COALESCE(poll_type, 'single'),
    is_anonymous = COALESCE(is_anonymous, false),
    is_closed = COALESCE(is_closed, false),
    updated_at = COALESCE(updated_at, created_at, now());

ALTER TABLE public.forum_polls
  ALTER COLUMN poll_type SET DEFAULT 'single',
  ALTER COLUMN poll_type SET NOT NULL,
  ALTER COLUMN is_anonymous SET DEFAULT false,
  ALTER COLUMN is_anonymous SET NOT NULL,
  ALTER COLUMN is_closed SET DEFAULT false,
  ALTER COLUMN is_closed SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_polls'::regclass
      AND conname = 'forum_polls_poll_type_check'
  ) THEN
    ALTER TABLE public.forum_polls
      ADD CONSTRAINT forum_polls_poll_type_check
      CHECK (poll_type IN ('single', 'multiple'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.forum_polls WHERE created_by IS NULL) THEN
    ALTER TABLE public.forum_polls ALTER COLUMN created_by SET NOT NULL;
  END IF;
END;
$$;

ALTER TABLE public.forum_user_reads
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id uuid;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_user_reads'
      AND column_name = 'topic_id'
  ) THEN
    UPDATE public.forum_user_reads
    SET entity_type = COALESCE(entity_type, 'topic'),
        entity_id = COALESCE(entity_id, topic_id)
    WHERE topic_id IS NOT NULL;
  END IF;
END;
$$;

DELETE FROM public.forum_user_reads
WHERE user_id IS NULL OR entity_type IS NULL OR entity_id IS NULL;

ALTER TABLE public.forum_user_reads
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN entity_type SET NOT NULL,
  ALTER COLUMN entity_id SET NOT NULL,
  ALTER COLUMN last_read_at SET DEFAULT now(),
  ALTER COLUMN last_read_at SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_user_reads'::regclass
      AND conname = 'forum_user_reads_entity_type_check'
  ) THEN
    ALTER TABLE public.forum_user_reads
      ADD CONSTRAINT forum_user_reads_entity_type_check
      CHECK (entity_type IN ('category', 'topic'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_user_reads'::regclass
      AND conname = 'forum_user_reads_user_entity_key'
  ) THEN
    ALTER TABLE public.forum_user_reads
      ADD CONSTRAINT forum_user_reads_user_entity_key
      UNIQUE (user_id, entity_type, entity_id);
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_forum_user_reads_entity
  ON public.forum_user_reads(entity_type, entity_id);

DROP FUNCTION IF EXISTS public.forum_mark_read(uuid, uuid);

CREATE OR REPLACE FUNCTION public.forum_mark_read(
  p_user_id uuid,
  p_entity_type text,
  p_entity_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_entity_type NOT IN ('category', 'topic') THEN
    RAISE EXCEPTION 'Invalid forum entity type';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'Cannot mark forum content as read for another user';
  END IF;

  INSERT INTO public.forum_user_reads (user_id, entity_type, entity_id, last_read_at)
  VALUES (p_user_id, p_entity_type, p_entity_id, now())
  ON CONFLICT (user_id, entity_type, entity_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.forum_mark_read(uuid, text, uuid)
  TO authenticated, service_role;

COMMIT;
