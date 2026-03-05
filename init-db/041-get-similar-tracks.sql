-- D3 Фаза 1+2: Похожие треки по метаданным (genre, mood, energy) или эмбеддингам
-- Фаза 1: method=metadata. Фаза 2: method=embeddings при audio_embedding

-- Настройки похожих треков (052 обновляет description)
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('similar_tracks', '{
    "enabled": true,
    "method": "metadata",
    "max_results": 10,
    "min_similarity": 0
  }'::jsonb, 'D3: Похожие треки. method: metadata | embeddings')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- SQL-функция: поиск похожих треков
CREATE OR REPLACE FUNCTION public.get_similar_tracks(
  p_track_id uuid,
  p_limit integer DEFAULT 10
)
RETURNS TABLE (
  id uuid,
  title text,
  cover_url text,
  audio_url text,
  duration integer,
  likes_count integer,
  plays_count integer,
  genre_id uuid,
  genre_name_ru text,
  username text,
  user_id uuid,
  similarity_score integer
) AS $$
DECLARE
  v_genre_id uuid;
  v_mood text;
  v_energy real;
  v_max_results int;
  v_enabled boolean;
  v_settings jsonb;
BEGIN
  -- Проверяем настройку
  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'similar_tracks' LIMIT 1;
  v_enabled := COALESCE((v_settings->>'enabled')::boolean, true);
  v_max_results := COALESCE((v_settings->>'max_results')::int, 10);
  IF NOT v_enabled OR p_limit <= 0 THEN RETURN; END IF;

  -- Получаем метаданные исходного трека
  SELECT t.genre_id, t.mood, t.energy
  INTO v_genre_id, v_mood, v_energy
  FROM tracks t
  WHERE t.id = p_track_id AND t.is_public = true;

  IF v_genre_id IS NULL AND v_mood IS NULL AND v_energy IS NULL THEN
    -- Нет метаданных для сравнения — возвращаем по популярности
    RETURN QUERY
    SELECT t.id, t.title, t.cover_url, t.audio_url, t.duration::integer,
           COALESCE(t.likes_count, 0)::integer, COALESCE(t.plays_count, 0)::integer,
           t.genre_id, g.name_ru, p.username, t.user_id, 0::integer AS similarity_score
    FROM tracks t
    LEFT JOIN genres g ON g.id = t.genre_id
    LEFT JOIN profiles p ON p.user_id = t.user_id
    WHERE t.id != p_track_id AND t.is_public = true AND t.status = 'completed'
    ORDER BY COALESCE(t.plays_count, 0) DESC
    LIMIT LEAST(p_limit, v_max_results);
    RETURN;
  END IF;

  RETURN QUERY
  WITH scored AS (
    SELECT t.id, t.title, t.cover_url, t.audio_url, t.duration, t.user_id,
           COALESCE(t.likes_count, 0) AS likes_count,
           COALESCE(t.plays_count, 0) AS plays_count,
           t.genre_id,
           (CASE WHEN t.genre_id = v_genre_id AND v_genre_id IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN v_mood IS NOT NULL AND t.mood IS NOT NULL
                   AND (t.mood ILIKE '%' || trim(split_part(v_mood, ',', 1)) || '%'
                        OR v_mood ILIKE '%' || trim(split_part(t.mood, ',', 1)) || '%')
              THEN 2 ELSE 0 END
            + CASE WHEN v_energy IS NOT NULL AND t.energy IS NOT NULL
                   AND abs(t.energy - v_energy) < 0.3 THEN 1 ELSE 0 END
           )::integer AS sim
    FROM tracks t
    WHERE t.id != p_track_id AND t.is_public = true AND t.status = 'completed'
  )
  SELECT s.id, s.title, s.cover_url, s.audio_url, s.duration::integer,
         s.likes_count::integer, s.plays_count::integer,
         s.genre_id, g.name_ru, p.username, s.user_id, s.sim AS similarity_score
  FROM scored s
  LEFT JOIN genres g ON g.id = s.genre_id
  LEFT JOIN profiles p ON p.user_id = s.user_id
  ORDER BY s.sim DESC, s.plays_count DESC
  LIMIT LEAST(p_limit, v_max_results);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_similar_tracks(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_similar_tracks(uuid, integer) TO anon;
