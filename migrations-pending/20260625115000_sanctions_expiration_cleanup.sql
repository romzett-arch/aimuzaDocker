-- Deterministic cleanup for expired account and forum sanctions.

CREATE OR REPLACE FUNCTION public.expire_blocks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER := 0;
BEGIN
  WITH expired_blocks AS (
    UPDATE public.user_blocks ub
    SET
      is_active = false,
      unblocked_at = now()
    WHERE ub.is_active = true
      AND ub.expires_at IS NOT NULL
      AND ub.expires_at <= now()
    RETURNING ub.id, ub.user_id
  ),
  affected_users AS (
    SELECT DISTINCT user_id FROM expired_blocks
  ),
  notifications_inserted AS (
    INSERT INTO public.notifications (user_id, type, title, message)
    SELECT
      au.user_id,
      'system',
      'Блокировка снята',
      'Срок вашей блокировки истёк. Вы снова можете пользоваться всеми функциями платформы.'
    FROM affected_users au
    RETURNING id
  ),
  logs_inserted AS (
    INSERT INTO public.role_change_logs (user_id, action, reason)
    SELECT
      au.user_id,
      'unblocked',
      'Автоматическая разблокировка по истечении срока'
    FROM affected_users au
    RETURNING id
  )
  SELECT COUNT(*)
  INTO v_expired_count
  FROM expired_blocks;

  RETURN COALESCE(v_expired_count, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_expire_warnings()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER := 0;
  v_user_id UUID;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expired_forum_warning_users (
    user_id UUID PRIMARY KEY
  ) ON COMMIT DROP;

  TRUNCATE pg_temp.expired_forum_warning_users;

  WITH expired_warnings AS (
    UPDATE public.forum_warnings fw
    SET is_active = false
    WHERE COALESCE(fw.is_active, true)
      AND fw.expires_at IS NOT NULL
      AND fw.expires_at <= now()
    RETURNING fw.user_id
  ),
  affected_users AS (
    INSERT INTO pg_temp.expired_forum_warning_users (user_id)
    SELECT DISTINCT user_id FROM expired_warnings
    ON CONFLICT (user_id) DO NOTHING
    RETURNING user_id
  )
  SELECT COUNT(*)
  INTO v_expired_count
  FROM expired_warnings;

  FOR v_user_id IN SELECT user_id FROM pg_temp.expired_forum_warning_users
  LOOP
    PERFORM public.forum_refresh_user_moderation_state(v_user_id);
  END LOOP;

  RETURN COALESCE(v_expired_count, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_expire_sanctions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_bans INTEGER := 0;
  v_expired_warnings INTEGER := 0;
  v_user_id UUID;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expired_forum_sanction_users (
    user_id UUID PRIMARY KEY
  ) ON COMMIT DROP;

  TRUNCATE pg_temp.expired_forum_sanction_users;

  WITH expired_bans AS (
    UPDATE public.forum_user_bans b
    SET is_active = false
    WHERE COALESCE(b.is_active, true)
      AND b.expires_at IS NOT NULL
      AND b.expires_at <= now()
    RETURNING b.user_id
  ),
  affected_ban_users AS (
    INSERT INTO pg_temp.expired_forum_sanction_users (user_id)
    SELECT DISTINCT user_id FROM expired_bans
    ON CONFLICT (user_id) DO NOTHING
    RETURNING user_id
  )
  SELECT COUNT(*)
  INTO v_expired_bans
  FROM expired_bans;

  WITH expired_warnings AS (
    UPDATE public.forum_warnings fw
    SET is_active = false
    WHERE COALESCE(fw.is_active, true)
      AND fw.expires_at IS NOT NULL
      AND fw.expires_at <= now()
    RETURNING fw.user_id
  ),
  affected_warning_users AS (
    INSERT INTO pg_temp.expired_forum_sanction_users (user_id)
    SELECT DISTINCT user_id FROM expired_warnings
    ON CONFLICT (user_id) DO NOTHING
    RETURNING user_id
  )
  SELECT COUNT(*)
  INTO v_expired_warnings
  FROM expired_warnings;

  FOR v_user_id IN SELECT user_id FROM pg_temp.expired_forum_sanction_users
  LOOP
    PERFORM public.forum_refresh_user_moderation_state(v_user_id);
  END LOOP;

  RETURN jsonb_build_object(
    'expired_bans', COALESCE(v_expired_bans, 0),
    'expired_warnings', COALESCE(v_expired_warnings, 0),
    'refreshed_users', (SELECT COUNT(*) FROM pg_temp.expired_forum_sanction_users)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_blocks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_expire_warnings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_expire_sanctions() TO authenticated;
