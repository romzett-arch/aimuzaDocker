-- ═══════════════════════════════════════════════════════════════════
-- СУПЕРАДМИН: romzett@mail.ru — AI Planet Sound
-- Защита на уровне БД: нельзя удалить, нельзя изменить email/пароль/роль
-- ═══════════════════════════════════════════════════════════════════

-- 1. Добавляем недостающие колонки в profiles если нет
DO $$
BEGIN
  -- display_name
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='display_name') THEN
    ALTER TABLE public.profiles ADD COLUMN display_name text;
  END IF;
  -- role
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='role') THEN
    ALTER TABLE public.profiles ADD COLUMN role text DEFAULT 'user';
  END IF;
  -- is_super_admin
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_super_admin') THEN
    ALTER TABLE public.profiles ADD COLUMN is_super_admin boolean DEFAULT false;
  END IF;
  -- is_protected
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_protected') THEN
    ALTER TABLE public.profiles ADD COLUMN is_protected boolean DEFAULT false;
  END IF;
  -- bio
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='bio') THEN
    ALTER TABLE public.profiles ADD COLUMN bio text;
  END IF;
  -- subscription_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='subscription_type') THEN
    ALTER TABLE public.profiles ADD COLUMN subscription_type text DEFAULT 'free';
  END IF;
  -- subscription_expires_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='subscription_expires_at') THEN
    ALTER TABLE public.profiles ADD COLUMN subscription_expires_at timestamptz;
  END IF;
  -- email
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='email') THEN
    ALTER TABLE public.profiles ADD COLUMN email text;
  END IF;
  -- generation_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='generation_count') THEN
    ALTER TABLE public.profiles ADD COLUMN generation_count integer DEFAULT 0;
  END IF;
  -- total_likes
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='total_likes') THEN
    ALTER TABLE public.profiles ADD COLUMN total_likes integer DEFAULT 0;
  END IF;
  -- followers_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='followers_count') THEN
    ALTER TABLE public.profiles ADD COLUMN followers_count integer DEFAULT 0;
  END IF;
  -- following_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='following_count') THEN
    ALTER TABLE public.profiles ADD COLUMN following_count integer DEFAULT 0;
  END IF;
  -- tracks_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='tracks_count') THEN
    ALTER TABLE public.profiles ADD COLUMN tracks_count integer DEFAULT 0;
  END IF;
  -- is_verified
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_verified') THEN
    ALTER TABLE public.profiles ADD COLUMN is_verified boolean DEFAULT false;
  END IF;
END $$;


-- 2. Создаём суперадмина в auth.users
INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, is_super_admin, raw_user_meta_data, created_at, updated_at)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'romzett@mail.ru',
  '$2a$10$xvxUl.RbTl/gbcwrQVjLn.5slqEqZn24TK/1zWy5PoFBMFWyPDYr6',
  now(),
  true,
  '{"display_name": "AI Planet Sound", "role": "superadmin"}'::jsonb,
  now(),
  now()
)
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  encrypted_password = EXCLUDED.encrypted_password,
  is_super_admin = true;


-- 3. Создаём профиль суперадмина
INSERT INTO public.profiles (user_id, username, display_name, email, balance, role, is_super_admin, is_protected, is_verified, subscription_type, generation_count, created_at, updated_at)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'AI Planet Sound',
  'AI Planet Sound',
  'romzett@mail.ru',
  999999,
  'superadmin',
  true,
  true,
  true,
  'premium',
  0,
  now(),
  now()
)
ON CONFLICT (user_id) DO UPDATE SET
  username = 'AI Planet Sound',
  display_name = 'AI Planet Sound',
  role = 'superadmin',
  is_super_admin = true,
  is_protected = true,
  is_verified = true,
  balance = 999999,
  subscription_type = 'premium';


-- 4. Назначаем роль admin в user_roles
INSERT INTO public.user_roles (user_id, role, created_at)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'admin',
  now()
)
ON CONFLICT DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════
-- ЗАЩИТА СУПЕРАДМИНА: ТРИГГЕРЫ (уровень БД — обойти невозможно)
-- ═══════════════════════════════════════════════════════════════════

-- 5a. Защита auth.users — запрет DELETE для суперадмина
CREATE OR REPLACE FUNCTION protect_superadmin_auth_delete()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_super_admin = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Суперадмин защищён на уровне базы данных. Удаление невозможно.';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_superadmin_auth_delete ON auth.users;
CREATE TRIGGER trg_protect_superadmin_auth_delete
  BEFORE DELETE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION protect_superadmin_auth_delete();

-- 5b. Защита auth.users — запрет UPDATE критических полей для суперадмина
CREATE OR REPLACE FUNCTION protect_superadmin_auth_update()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_super_admin = true THEN
    -- Нельзя менять email, пароль, is_super_admin
    IF NEW.email != OLD.email THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить email суперадмина.';
    END IF;
    IF NEW.encrypted_password != OLD.encrypted_password THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить пароль суперадмина.';
    END IF;
    IF NEW.is_super_admin != OLD.is_super_admin THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя снять статус суперадмина.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_superadmin_auth_update ON auth.users;
CREATE TRIGGER trg_protect_superadmin_auth_update
  BEFORE UPDATE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION protect_superadmin_auth_update();

-- 5c. Защита profiles — запрет DELETE для суперадмина
CREATE OR REPLACE FUNCTION protect_superadmin_profile_delete()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_protected = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Профиль суперадмина защищён. Удаление невозможно.';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_superadmin_profile_delete ON public.profiles;
CREATE TRIGGER trg_protect_superadmin_profile_delete
  BEFORE DELETE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION protect_superadmin_profile_delete();

-- 5d. Защита profiles — запрет изменения защитных полей
CREATE OR REPLACE FUNCTION protect_superadmin_profile_update()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_protected = true THEN
    -- Нельзя снять защиту
    IF NEW.is_protected != OLD.is_protected THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя снять защиту суперадмина.';
    END IF;
    -- Нельзя снять is_super_admin
    IF NEW.is_super_admin != OLD.is_super_admin THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить статус суперадмина.';
    END IF;
    -- Нельзя понизить роль
    IF NEW.role != 'super_admin' AND OLD.role = 'super_admin' THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя понизить роль суперадмина.';
    END IF;
    -- Нельзя заблокировать
    IF NEW.user_id != OLD.user_id THEN
      RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя изменить user_id суперадмина.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_superadmin_profile_update ON public.profiles;
CREATE TRIGGER trg_protect_superadmin_profile_update
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION protect_superadmin_profile_update();

-- 5e. Защита user_roles — нельзя удалить роль суперадмина
CREATE OR REPLACE FUNCTION protect_superadmin_role_delete()
RETURNS TRIGGER AS $$
DECLARE
  _is_protected boolean;
BEGIN
  SELECT is_protected INTO _is_protected FROM public.profiles WHERE user_id = OLD.user_id;
  IF _is_protected = true THEN
    RAISE EXCEPTION 'ЗАПРЕЩЕНО: Нельзя удалить роль суперадмина.';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_superadmin_role_delete ON public.user_roles;
CREATE TRIGGER trg_protect_superadmin_role_delete
  BEFORE DELETE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION protect_superadmin_role_delete();


-- ═══════════════════════════════════════════════════════════════════
-- НЕДОСТАЮЩИЕ ТАБЛИЦЫ И ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════════

-- 6. Таблица ad_settings (если не существует)
CREATE TABLE IF NOT EXISTS public.ad_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 7. Таблица ad_campaigns (если не существует)
CREATE TABLE IF NOT EXISTS public.ad_campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slot_key text,
  status text DEFAULT 'draft',
  budget numeric DEFAULT 0,
  spent numeric DEFAULT 0,
  impressions integer DEFAULT 0,
  clicks integer DEFAULT 0,
  image_url text,
  link_url text,
  html_content text,
  start_date timestamptz,
  end_date timestamptz,
  targeting jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 8. Функция get_ad_for_slot
CREATE OR REPLACE FUNCTION public.get_ad_for_slot(
  p_slot_key text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_device_type text DEFAULT 'desktop'
)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'image_url', c.image_url,
    'link_url', c.link_url,
    'html_content', c.html_content
  ) INTO result
  FROM public.ad_campaigns c
  WHERE c.slot_key = p_slot_key
    AND c.status = 'active'
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
  ORDER BY random()
  LIMIT 1;

  IF result IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  -- Увеличиваем счётчик показов
  UPDATE public.ad_campaigns SET impressions = impressions + 1 WHERE id = (result->>'id')::uuid;

  RETURN result;
END;
$$ LANGUAGE plpgsql;


-- 9. Таблица playlists (если не существует)
CREATE TABLE IF NOT EXISTS public.playlists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  cover_url text,
  is_public boolean DEFAULT true,
  tracks_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.playlist_tracks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  playlist_id uuid REFERENCES public.playlists(id) ON DELETE CASCADE,
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  position integer DEFAULT 0,
  added_at timestamptz DEFAULT now()
);

-- 10. Таблица follows (если не существует)
CREATE TABLE IF NOT EXISTS public.follows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  following_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(follower_id, following_id)
);

-- 11. Таблица comments (если не существует)
CREATE TABLE IF NOT EXISTS public.comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  content text NOT NULL,
  parent_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 12. Таблица notifications (если не существует)
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  type text NOT NULL,
  title text,
  message text,
  data jsonb DEFAULT '{}'::jsonb,
  is_read boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- 13. Таблица messages (если не существует)
CREATE TABLE IF NOT EXISTS public.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  receiver_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  content text,
  attachment_url text,
  is_read boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- 14. Таблица lyrics (если не существует)
CREATE TABLE IF NOT EXISTS public.lyrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  title text,
  content text NOT NULL,
  genre text,
  mood text,
  language text DEFAULT 'ru',
  is_public boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 15. Таблица prompts (если не существует)
CREATE TABLE IF NOT EXISTS public.prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  prompt_text text NOT NULL,
  genre text,
  tags text[],
  price integer DEFAULT 0,
  is_public boolean DEFAULT false,
  uses_count integer DEFAULT 0,
  rating numeric DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 16. Таблица payments (если не существует)
CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  amount numeric NOT NULL,
  currency text DEFAULT 'RUB',
  status text DEFAULT 'pending',
  provider text,
  provider_payment_id text,
  description text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 17. Таблица announcements (если не существует)
CREATE TABLE IF NOT EXISTS public.announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  content text NOT NULL,
  type text DEFAULT 'info',
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz
);

-- 18. Полезные функции
CREATE OR REPLACE FUNCTION public.get_user_stats(p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'tracks_count', (SELECT COUNT(*) FROM public.tracks WHERE user_id = p_user_id),
    'total_likes', COALESCE((SELECT SUM(likes_count) FROM public.tracks WHERE user_id = p_user_id), 0),
    'followers_count', (SELECT COUNT(*) FROM public.user_follows WHERE following_id = p_user_id),
    'following_count', (SELECT COUNT(*) FROM public.user_follows WHERE follower_id = p_user_id)
  ) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 19. Системные настройки
CREATE TABLE IF NOT EXISTS public.system_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb DEFAULT '{}'::jsonb,
  description text,
  updated_at timestamptz DEFAULT now()
);

-- Вставляем настройки по умолчанию
INSERT INTO public.system_settings (key, value, description) VALUES
  ('maintenance', '{"enabled": false, "message": ""}'::jsonb, 'Режим обслуживания'),
  ('registration', '{"enabled": true, "require_invite": false}'::jsonb, 'Настройки регистрации'),
  ('generation', '{"daily_limit_free": 5, "daily_limit_premium": 50}'::jsonb, 'Лимиты генерации'),
  ('payments', '{"yookassa_enabled": false, "robokassa_enabled": false}'::jsonb, 'Настройки платежей')
ON CONFLICT (key) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════
-- ПРОВЕРКА: Попытка удалить суперадмина (должна упасть)
-- ═══════════════════════════════════════════════════════════════════
-- DO $$ BEGIN
--   DELETE FROM auth.users WHERE email = 'romzett@mail.ru';
--   RAISE NOTICE 'ОШИБКА: удаление прошло!';
-- EXCEPTION WHEN OTHERS THEN
--   RAISE NOTICE 'OK: Защита работает — %', SQLERRM;
-- END $$;

SELECT 'СУПЕРАДМИН СОЗДАН И ЗАЩИЩЁН' as status;
