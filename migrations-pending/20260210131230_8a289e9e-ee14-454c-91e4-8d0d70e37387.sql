
-- ==========================================================
-- SUPER ADMIN FULL PROTECTION SUITE
-- ==========================================================

-- 1. BLOCK INSERT of super_admin role (closes main vulnerability)
CREATE OR REPLACE FUNCTION public.protect_super_admin_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Block any INSERT of super_admin role
  IF NEW.role = 'super_admin' THEN
    -- Log the attempt
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
    VALUES (
      NEW.user_id,
      'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка создания роли super_admin заблокирована',
      jsonb_build_object('operation', 'INSERT', 'blocked', true, 'target_user', NEW.user_id)
    );
    
    -- Send strict warning notification to the attacker
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Ваша попытка присвоить роль super_admin зафиксирована и заблокирована. Все подобные действия логируются и могут привести к немедленной блокировке аккаунта.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
    END IF;
    
    -- Notify all super_admins about the attempt
    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    SELECT ur.user_id, 'system', 
      '🚨 ALERT: Попытка эскалации привилегий',
      'Пользователь ' || COALESCE(auth.uid()::text, 'unknown') || ' попытался создать роль super_admin для ' || NEW.user_id::text || '. Действие заблокировано.',
      '00000000-0000-0000-0000-000000000000'::uuid
    FROM public.user_roles ur WHERE ur.role = 'super_admin';
    
    RAISE EXCEPTION 'Создание роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_insert_trigger ON public.user_roles;
CREATE TRIGGER protect_super_admin_insert_trigger
  BEFORE INSERT ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_insert();


-- 2. BLOCK role_invitations for super_admin
CREATE OR REPLACE FUNCTION public.protect_super_admin_invitation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role::text = 'super_admin' THEN
    -- Log and notify
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка создать приглашение на роль super_admin зафиксирована и заблокирована. Повторные попытки приведут к блокировке аккаунта.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
      
      -- Notify super_admins
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      SELECT ur.user_id, 'system',
        '🚨 ALERT: Попытка создания инвайта super_admin',
        'Пользователь ' || auth.uid()::text || ' попытался создать приглашение на роль super_admin. Заблокировано.',
        '00000000-0000-0000-0000-000000000000'::uuid
      FROM public.user_roles ur WHERE ur.role = 'super_admin';
    END IF;
    
    RAISE EXCEPTION 'Приглашение на роль super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_invitation_trigger ON public.role_invitations;
CREATE TRIGGER protect_super_admin_invitation_trigger
  BEFORE INSERT ON public.role_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_invitation();


-- 3. PROTECT super_admin from Shield system (forum bans, mutes, silences)
CREATE OR REPLACE FUNCTION public.protect_super_admin_forum_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if target user is super_admin
  IF public.is_super_admin(NEW.user_id) THEN
    -- Block any attempt to ban/mute/silence super_admin
    IF (NEW.is_banned = true AND (OLD.is_banned IS NULL OR OLD.is_banned = false))
       OR (NEW.is_muted = true AND (OLD.is_muted IS NULL OR OLD.is_muted = false))
       OR (NEW.is_silenced = true AND (OLD.is_silenced IS NULL OR OLD.is_silenced = false)) THEN
      
      -- Force reset punitive fields
      NEW.is_banned := false;
      NEW.banned_until := NULL;
      NEW.ban_reason := NULL;
      NEW.is_muted := false;
      NEW.muted_until := NULL;
      NEW.is_silenced := false;
      NEW.silenced_until := NULL;
      NEW.silence_reason := NULL;
      NEW.warnings_count := 0;
      
      -- Notify the attacker
      IF auth.uid() IS NOT NULL AND auth.uid() != NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, message, actor_id)
        VALUES (
          auth.uid(),
          'system',
          '⛔ ДЕЙСТВИЕ ЗАБЛОКИРОВАНО',
          'Попытка применить ограничения к super_admin зафиксирована. Подобные действия запрещены и логируются. Повторные попытки приведут к немедленной блокировке.',
          '00000000-0000-0000-0000-000000000000'::uuid
        );
      END IF;
      
      -- Notify super_admins
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      SELECT ur.user_id, 'system',
        '🚨 ALERT: Попытка ограничить super_admin',
        'Попытка бана/мута/сайленса super_admin от ' || COALESCE(auth.uid()::text, 'system') || '. Действие нейтрализовано.',
        '00000000-0000-0000-0000-000000000000'::uuid
      FROM public.user_roles ur WHERE ur.role = 'super_admin' AND ur.user_id != NEW.user_id;
      
      -- Log
      INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
      VALUES (
        NEW.user_id,
        'access_attempt_blocked',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
        'Попытка ограничить super_admin через Shield',
        jsonb_build_object('attempted_ban', OLD.is_banned IS DISTINCT FROM NEW.is_banned, 
                          'attempted_mute', OLD.is_muted IS DISTINCT FROM NEW.is_muted,
                          'attempted_silence', OLD.is_silenced IS DISTINCT FROM NEW.is_silenced)
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_forum_stats_trigger ON public.forum_user_stats;
CREATE TRIGGER protect_super_admin_forum_stats_trigger
  BEFORE UPDATE ON public.forum_user_stats
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_forum_stats();


-- 4. PROTECT super_admin from user_blocks (account-level blocking)
-- The block_user() function already has protection, but add trigger for direct INSERT bypass
CREATE OR REPLACE FUNCTION public.protect_super_admin_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.is_super_admin(NEW.user_id) THEN
    -- Notify attacker
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка заблокировать super_admin зафиксирована. Это действие строго запрещено. Повторные попытки приведут к немедленным последствиям.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
    END IF;
    
    -- Notify super_admins
    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    SELECT ur.user_id, 'system',
      '🚨 ALERT: Попытка блокировки super_admin',
      'Пользователь ' || COALESCE(auth.uid()::text, 'unknown') || ' попытался заблокировать super_admin. Заблокировано.',
      '00000000-0000-0000-0000-000000000000'::uuid
    FROM public.user_roles ur WHERE ur.role = 'super_admin';
    
    -- Log
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (
      NEW.user_id,
      'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка блокировки super_admin через user_blocks'
    );
    
    RAISE EXCEPTION 'Блокировка super_admin запрещена. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_block_trigger ON public.user_blocks;
CREATE TRIGGER protect_super_admin_block_trigger
  BEFORE INSERT ON public.user_blocks
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_block();


-- 5. Also protect admins from being given super_admin via UPDATE on user_roles
-- (strengthen existing trigger to also handle edge cases)
CREATE OR REPLACE FUNCTION public.protect_super_admin_role_v2()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Block DELETE of super_admin
  IF TG_OP = 'DELETE' AND OLD.role = 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (OLD.user_id, 'access_attempt_blocked', 
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка удаления роли super_admin');
    
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (auth.uid(), 'system', '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка удалить роль super_admin зафиксирована и заблокирована.',
        '00000000-0000-0000-0000-000000000000'::uuid);
    END IF;
    
    RAISE EXCEPTION 'Удаление роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  -- Block UPDATE changing super_admin to something else
  IF TG_OP = 'UPDATE' AND OLD.role = 'super_admin' AND NEW.role != 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (OLD.user_id, 'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка изменения роли super_admin');
    
    RAISE EXCEPTION 'Изменение роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  -- Block UPDATE setting role TO super_admin
  IF TG_OP = 'UPDATE' AND NEW.role = 'super_admin' AND OLD.role != 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (NEW.user_id, 'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка присвоения роли super_admin через UPDATE');
    
    RAISE EXCEPTION 'Присвоение роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- Replace old triggers with new comprehensive one
DROP TRIGGER IF EXISTS protect_super_admin_role ON public.user_roles;
DROP TRIGGER IF EXISTS audit_super_admin_access ON public.user_roles;

CREATE TRIGGER protect_super_admin_role_v2_trigger
  BEFORE INSERT OR UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_role_v2();

-- Note: protect_super_admin_insert_trigger handles INSERT separately with more detailed logging,
-- and protect_super_admin_role_v2_trigger handles UPDATE/DELETE.
-- For INSERT, both triggers will fire but protect_super_admin_insert catches it first.
