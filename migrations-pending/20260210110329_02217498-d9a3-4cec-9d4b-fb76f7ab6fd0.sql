-- RPC для подсчёта статистики пользователей на стороне сервера
-- вместо загрузки ВСЕХ профилей на клиент
CREATE OR REPLACE FUNCTION public.get_user_stats()
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total', (SELECT count(*) FROM profiles),
    'new_today', (SELECT count(*) FROM profiles WHERE created_at >= date_trunc('day', now())),
    'active_today', (SELECT count(*) FROM profiles WHERE last_seen_at >= date_trunc('day', now())),
    'active_last_hour', (SELECT count(*) FROM profiles WHERE last_seen_at >= now() - interval '1 hour')
  );
$$;