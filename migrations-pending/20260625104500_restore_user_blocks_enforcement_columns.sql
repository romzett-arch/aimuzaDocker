-- Restore account-block enforcement columns when older/local databases drifted.

ALTER TABLE public.user_blocks
  ADD COLUMN IF NOT EXISTS blocked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS unblocked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS unblocked_by UUID,
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN;

UPDATE public.user_blocks
SET blocked_at = COALESCE(blocked_at, created_at, now())
WHERE blocked_at IS NULL;

UPDATE public.user_blocks
SET is_active = true
WHERE is_active IS NULL;

ALTER TABLE public.user_blocks
  ALTER COLUMN blocked_at SET DEFAULT now(),
  ALTER COLUMN blocked_at SET NOT NULL,
  ALTER COLUMN is_active SET DEFAULT true,
  ALTER COLUMN is_active SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_blocks_user_id
  ON public.user_blocks(user_id);

CREATE INDEX IF NOT EXISTS idx_user_blocks_active
  ON public.user_blocks(user_id, is_active)
  WHERE is_active = true;
