-- Distribution Voting Integration
-- 1. Add 'voting' to distribution_status CHECK constraint
-- 2. Rename forum category "Голосование" to "Голосование на дистрибуцию"
-- 3. Update create_voting_forum_topic title template

-- 1. Drop old constraint and add new one with 'voting'
ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_distribution_status_check;
ALTER TABLE public.tracks ADD CONSTRAINT tracks_distribution_status_check
  CHECK (distribution_status IN ('none', 'pending_moderation', 'approved', 'rejected', 'pending_master', 'processing', 'completed', 'voting'));

-- 2. Rename forum category
UPDATE public.forum_categories
SET name = 'Distribution Voting', name_ru = 'Голосование на дистрибуцию'
WHERE id = '667eca41-29ad-40bf-bf92-cceec00f5875';

-- 3. Update create_voting_forum_topic: title template
CREATE OR REPLACE FUNCTION public.create_voting_forum_topic(
  p_track_id UUID,
  p_moderator_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track RECORD;
  v_author_username TEXT;
  v_genre_name TEXT;
  v_topic_title TEXT;
  v_topic_content TEXT;
  v_slug TEXT;
  v_topic_id UUID;
  v_voting_category_id UUID := '667eca41-29ad-40bf-bf92-cceec00f5875';
  v_voting_ends TEXT;
BEGIN
  SELECT id, title, user_id, cover_url, genre_id, voting_ends_at
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found: %', p_track_id;
  END IF;

  SELECT username INTO v_author_username
  FROM public.profiles
  WHERE user_id = v_track.user_id;

  v_author_username := COALESCE(v_author_username, 'Автор');

  IF v_track.genre_id IS NOT NULL THEN
    SELECT name_ru INTO v_genre_name
    FROM public.genres
    WHERE id = v_track.genre_id;
  END IF;

  IF v_track.voting_ends_at IS NOT NULL THEN
    v_voting_ends := to_char(v_track.voting_ends_at AT TIME ZONE 'Europe/Moscow', 'DD.MM.YYYY в HH24:MI') || ' (МСК)';
  ELSE
    v_voting_ends := 'не указано';
  END IF;

  -- Updated title: "Голосование на дистрибуцию: {title}"
  v_topic_title := '🗳️ Голосование на дистрибуцию: ' || v_track.title;

  v_topic_content := '## 🎵 ' || v_track.title || E'\n\n' ||
    '**Исполнитель:** [' || v_author_username || '](/profile/' || v_track.user_id || ')' || E'\n';

  IF v_genre_name IS NOT NULL THEN
    v_topic_content := v_topic_content || '**Жанр:** ' || v_genre_name || E'\n';
  END IF;

  v_topic_content := v_topic_content || '**Голосование до:** ' || v_voting_ends || E'\n\n' ||
    '---' || E'\n\n' ||
    'Этот трек проходит голосование сообщества перед отправкой на дистрибуцию. ' ||
    'Послушайте и оцените — ваш голос влияет на итоговое решение.' || E'\n\n' ||
    '👇 **Используйте виджет ниже, чтобы прослушать трек и проголосовать.**' || E'\n\n' ||
    '---' || E'\n\n' ||
    '📋 [Правила дистрибуции](/distribution-requirements) · ' ||
    '🎧 [Профиль исполнителя](/profile/' || v_track.user_id || ')';

  v_slug := lower(v_topic_title);
  v_slug := regexp_replace(v_slug, '[^a-zа-яё0-9\s]', '', 'gi');
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := left(v_slug, 80) || '-' || to_hex(extract(epoch from now())::bigint);

  INSERT INTO public.forum_topics (
    category_id,
    user_id,
    title,
    slug,
    content,
    excerpt,
    track_id,
    is_pinned,
    is_hidden
  ) VALUES (
    v_voting_category_id,
    p_moderator_id,
    v_topic_title,
    v_slug,
    v_topic_content,
    'Трек «' || v_track.title || '» от ' || v_author_username || ' — голосование сообщества перед дистрибуцией.',
    p_track_id,
    true,
    false
  )
  RETURNING id INTO v_topic_id;

  UPDATE public.tracks
  SET forum_topic_id = v_topic_id
  WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;
