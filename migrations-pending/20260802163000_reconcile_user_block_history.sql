-- Preserve legacy profile blocks in the canonical audit history and make the
-- profile projection repairable from user_blocks.

UPDATE public.user_blocks
SET is_active = false,
    unblocked_at = COALESCE(unblocked_at, now())
WHERE is_active
  AND expires_at IS NOT NULL
  AND expires_at <= now();

INSERT INTO public.user_blocks (
  user_id,
  blocked_by,
  reason,
  blocked_at,
  is_active,
  created_at
)
SELECT
  p.user_id,
  p.blocked_by,
  p.blocked_reason,
  p.blocked_at,
  true,
  p.blocked_at
FROM public.profiles p
WHERE p.is_blocked IS TRUE
  AND p.blocked_by IS NOT NULL
  AND p.blocked_at IS NOT NULL
  AND NULLIF(btrim(p.blocked_reason), '') IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.user_blocks b
    WHERE b.user_id = p.user_id
      AND b.is_active
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_blocks_one_active_per_user
  ON public.user_blocks(user_id)
  WHERE is_active;

CREATE OR REPLACE FUNCTION public.admin_reconcile_expired_blocks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_count integer := 0;
  v_step_count integer := 0;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_admin(v_actor_id) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  UPDATE public.user_blocks
  SET is_active = false,
      unblocked_at = COALESCE(unblocked_at, now())
  WHERE is_active
    AND expires_at IS NOT NULL
    AND expires_at <= now();
  GET DIAGNOSTICS v_step_count = ROW_COUNT;
  v_count := v_count + v_step_count;

  UPDATE public.profiles p
  SET is_blocked = false,
      blocked_at = NULL,
      blocked_reason = NULL,
      blocked_by = NULL
  WHERE p.is_blocked IS TRUE
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_blocks b
      WHERE b.user_id = p.user_id
        AND b.is_active
        AND (b.expires_at IS NULL OR b.expires_at > now())
    );
  GET DIAGNOSTICS v_step_count = ROW_COUNT;
  v_count := v_count + v_step_count;

  WITH current_blocks AS (
    SELECT DISTINCT ON (b.user_id)
      b.user_id,
      b.blocked_at,
      b.reason,
      b.blocked_by
    FROM public.user_blocks b
    WHERE b.is_active
      AND (b.expires_at IS NULL OR b.expires_at > now())
    ORDER BY b.user_id, b.blocked_at DESC, b.id DESC
  )
  UPDATE public.profiles p
  SET is_blocked = true,
      blocked_at = c.blocked_at,
      blocked_reason = c.reason,
      blocked_by = c.blocked_by
  FROM current_blocks c
  WHERE p.user_id = c.user_id
    AND (
      p.is_blocked IS DISTINCT FROM true
      OR p.blocked_at IS DISTINCT FROM c.blocked_at
      OR p.blocked_reason IS DISTINCT FROM c.reason
      OR p.blocked_by IS DISTINCT FROM c.blocked_by
    );
  GET DIAGNOSTICS v_step_count = ROW_COUNT;
  v_count := v_count + v_step_count;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reconcile_expired_blocks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reconcile_expired_blocks() TO authenticated, service_role;
