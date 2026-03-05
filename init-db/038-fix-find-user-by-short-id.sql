-- Исправление find_user_by_short_id: поддержка short_id из URL (первые 6 символов UUID)
-- Проблема: 006 использовала p.short_id, но колонка не заполнена в seed.
-- Решение: искать по user_id::text LIKE short_id || '%' (как в 001-schema)

DROP FUNCTION IF EXISTS public.find_user_by_short_id(text);

CREATE OR REPLACE FUNCTION public.find_user_by_short_id(short_id TEXT)
RETURNS TABLE(user_id uuid, username text, display_name text, avatar_url text) AS $$
BEGIN
  RETURN QUERY
  SELECT p.user_id, p.username, p.display_name, p.avatar_url
  FROM public.profiles p
  WHERE p.user_id::text LIKE (find_user_by_short_id.short_id || '%')
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
