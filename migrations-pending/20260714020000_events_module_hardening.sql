-- Harden contests and announcements: safe actor handling, targeted delivery,
-- transactional contest cancellation, and service lifecycle support.

DO $$
BEGIN
  IF to_regprocedure('public.submit_contest_entry_impl(uuid,uuid,uuid)') IS NULL THEN
    ALTER FUNCTION public.submit_contest_entry(UUID, UUID, UUID)
      RENAME TO submit_contest_entry_impl;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_contest_entry_impl(UUID, UUID, UUID) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.submit_contest_entry(
  p_contest_id UUID,
  p_track_id UUID,
  p_user_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(current_setting('request.jwt.claim.role', true), '');
  v_actor UUID := COALESCE(p_user_id, auth.uid());
BEGIN
  IF auth.uid() IS NULL AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Необходима авторизация';
  END IF;

  IF v_role <> 'service_role'
     AND p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid()
     AND NOT public.is_admin(auth.uid())
     AND NOT public.is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Нельзя подавать заявку от имени другого пользователя';
  END IF;

  RETURN public.submit_contest_entry_impl(p_contest_id, p_track_id, v_actor);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_contest_entry(UUID, UUID, UUID) TO authenticated;

ALTER TABLE public.admin_announcements
  ADD COLUMN IF NOT EXISTS target_audience JSONB DEFAULT NULL;

CREATE OR REPLACE FUNCTION public.get_active_announcements()
RETURNS SETOF public.admin_announcements
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT a.*
  FROM public.admin_announcements a
  WHERE auth.uid() IS NOT NULL
    AND a.is_published IS TRUE
    AND (a.publish_at IS NULL OR a.publish_at <= now())
    AND (a.expires_at IS NULL OR a.expires_at >= now())
    AND NOT EXISTS (
      SELECT 1 FROM public.announcement_dismissals d
      WHERE d.announcement_id = a.id AND d.user_id = auth.uid()
    )
    AND (
      a.target_audience IS NULL
      OR (
        (
          NOT (a.target_audience ? 'roles')
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(a.target_audience->'roles') wanted(role)
            WHERE wanted.role IN (
              SELECT ur.role::text FROM public.user_roles ur WHERE ur.user_id = auth.uid()
              UNION
              SELECT COALESCE(p.role, 'user') FROM public.profiles p WHERE p.user_id = auth.uid()
            )
          )
        )
        AND (
          NOT (a.target_audience ? 'min_tracks')
          OR (SELECT COUNT(*) FROM public.tracks t WHERE t.user_id = auth.uid())
             >= COALESCE((a.target_audience->>'min_tracks')::INTEGER, 0)
        )
        AND (
          NOT (a.target_audience ? 'min_days_registered')
          OR EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = auth.uid()
              AND p.created_at <= now() - make_interval(days => COALESCE((a.target_audience->>'min_days_registered')::INTEGER, 0))
          )
        )
        AND (
          NOT (a.target_audience ? 'has_subscription')
          OR (a.target_audience->>'has_subscription')::BOOLEAN = EXISTS (
            SELECT 1 FROM public.user_subscriptions us
            WHERE us.user_id = auth.uid()
              AND us.status IN ('active', 'cancelled')
              AND us.current_period_end > now()
          )
        )
      )
    )
  ORDER BY a.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_announcements() TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_contest(p_contest_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contest public.contests%ROWTYPE;
  v_entry RECORD;
  v_refunded INTEGER := 0;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  SELECT * INTO v_contest
  FROM public.contests
  WHERE id = p_contest_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Конкурс не найден'; END IF;
  IF v_contest.status = 'completed' THEN
    RAISE EXCEPTION 'Завершённый конкурс нельзя отменить';
  END IF;
  IF v_contest.status = 'cancelled' THEN RETURN 0; END IF;

  FOR v_entry IN
    SELECT * FROM public.contest_entries
    WHERE contest_id = p_contest_id
      AND COALESCE(entry_fee_charged, 0) > 0
      AND entry_fee_refunded_at IS NULL
    FOR UPDATE
  LOOP
    SELECT balance INTO v_balance_before
    FROM public.profiles WHERE user_id = v_entry.user_id FOR UPDATE;

    UPDATE public.profiles
    SET balance = balance + v_entry.entry_fee_charged
    WHERE user_id = v_entry.user_id
    RETURNING balance INTO v_balance_after;

    UPDATE public.contest_entries
    SET entry_fee_refunded_at = now()
    WHERE id = v_entry.id;

    INSERT INTO public.balance_transactions (
      user_id, amount, type, description, reference_id, reference_type,
      balance_before, balance_after, metadata
    ) VALUES (
      v_entry.user_id, v_entry.entry_fee_charged, 'contest_entry_refund',
      'Возврат взноса: конкурс "' || v_contest.title || '" отменён администрацией',
      v_entry.id, 'contest_entry', v_balance_before, v_balance_after,
      jsonb_build_object('contest_id', p_contest_id, 'reason', 'admin_cancelled')
    );
    v_refunded := v_refunded + 1;
  END LOOP;

  UPDATE public.contests
  SET status = 'cancelled', final_prize_pool = 0, finalized_at = now()
  WHERE id = p_contest_id;

  RETURN v_refunded;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_contest(UUID) TO authenticated;

-- finalize_contest already performs the full admin check. Permit the internal
-- lifecycle worker when it sets an explicit transaction-local service claim.
CREATE OR REPLACE FUNCTION public.can_finalize_contest()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_admin(auth.uid())
      OR public.is_super_admin(auth.uid())
      OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role';
$$;

-- Replace the authorization expression without duplicating the large function body.
DO $$
DECLARE
  v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.finalize_contest(uuid)'::regprocedure)
  INTO v_definition;
  v_definition := replace(
    v_definition,
    'IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN',
    'IF NOT public.can_finalize_contest() THEN'
  );
  EXECUTE v_definition;
END;
$$;
