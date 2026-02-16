-- ═══════════════════════════════════════════════════════════════════
-- FIX: handle_new_user trigger — использовать username из metadata,
-- а не email целиком
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    NEW.email,
    100,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
    display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
    email = COALESCE(EXCLUDED.email, public.profiles.email);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ═══════════════════════════════════════════════════════════════════
-- FIX: Исправляем существующие профили где username = email
-- ═══════════════════════════════════════════════════════════════════

UPDATE public.profiles p
SET
  username = COALESCE(
    (SELECT u.raw_user_meta_data->>'username' FROM auth.users u WHERE u.id = p.user_id),
    split_part(p.email, '@', 1),
    split_part((SELECT u.email FROM auth.users u WHERE u.id = p.user_id), '@', 1)
  ),
  display_name = COALESCE(
    NULLIF(p.display_name, ''),
    (SELECT u.raw_user_meta_data->>'username' FROM auth.users u WHERE u.id = p.user_id),
    split_part(p.email, '@', 1),
    split_part((SELECT u.email FROM auth.users u WHERE u.id = p.user_id), '@', 1)
  ),
  email = COALESCE(
    NULLIF(p.email, ''),
    (SELECT u.email FROM auth.users u WHERE u.id = p.user_id)
  )
WHERE p.username LIKE '%@%'
  AND p.is_protected IS NOT TRUE;

SELECT 'USERNAME FIX APPLIED' as status;
