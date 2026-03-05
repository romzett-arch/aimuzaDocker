-- Hero stats: один RPC вместо 4 HTTP-запросов
-- Минимизирует количество соединений и ускоряет загрузку лендинга

CREATE OR REPLACE FUNCTION public.get_hero_stats()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_tracks BIGINT;
  v_public_tracks BIGINT;
  v_total_users BIGINT;
  v_total_creators BIGINT;
BEGIN
  SELECT COUNT(*) INTO v_total_tracks FROM tracks WHERE status = 'completed';
  SELECT COUNT(*) INTO v_public_tracks FROM tracks WHERE status = 'completed' AND is_public = true;
  SELECT COUNT(*) INTO v_total_users FROM profiles;
  SELECT COUNT(DISTINCT user_id) INTO v_total_creators FROM tracks WHERE status = 'completed';

  RETURN jsonb_build_object(
    'totalTracks', COALESCE(v_total_tracks, 0),
    'publicTracks', COALESCE(v_public_tracks, 0),
    'totalUsers', COALESCE(v_total_users, 0),
    'totalCreators', COALESCE(v_total_creators, 0)
  );
END;
$$;

-- RLS: функция SECURITY DEFINER, доступна анонимно для лендинга
GRANT EXECUTE ON FUNCTION public.get_hero_stats() TO anon;
GRANT EXECUTE ON FUNCTION public.get_hero_stats() TO authenticated;
