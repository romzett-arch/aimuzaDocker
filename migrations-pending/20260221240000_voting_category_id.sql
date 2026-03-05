-- 1. Save the real ID and slug of the "Голосование" category into settings
INSERT INTO settings (key, value, description)
SELECT 'forum_voting_category_id', id::text, 'ID категории форума для голосования'
FROM forum_categories
WHERE name_ru = 'Голосование' OR name_ru = 'Голосование на дистрибуцию' OR slug IN ('news','voting')
LIMIT 1
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO settings (key, value, description)
SELECT 'forum_voting_category_slug', slug, 'Slug категории форума для голосования'
FROM forum_categories
WHERE name_ru = 'Голосование' OR name_ru = 'Голосование на дистрибуцию' OR slug IN ('news','voting')
LIMIT 1
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- 2. RPC: read category ID from settings, use U&'' for emoji to avoid encoding issues
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
  v_voting_category_id UUID;
  v_voting_ends TEXT;
BEGIN
  SELECT value::uuid INTO v_voting_category_id
  FROM settings WHERE key = 'forum_voting_category_id';

  IF v_voting_category_id IS NULL THEN
    RAISE EXCEPTION 'forum_voting_category_id not found in settings';
  END IF;

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
    v_voting_ends := to_char(v_track.voting_ends_at AT TIME ZONE 'Europe/Moscow', U&'DD.MM.YYYY \0432 HH24:MI') || U&' (\041C\0421\041A)';
  ELSE
    v_voting_ends := U&'\043D\0435 \0443\043A\0430\0437\0430\043D\043E';
  END IF;

  v_topic_title := U&'\+01F5F3\FE0F \0413\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \043D\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\044E: ' || v_track.title;

  v_topic_content := '## ' || U&'\+01F3B5' || ' ' || v_track.title || E'\n\n' ||
    U&'**\0418\0441\043F\043E\043B\043D\0438\0442\0435\043B\044C:** [' || v_author_username || '](/profile/' || v_track.user_id || ')' || E'\n';

  IF v_genre_name IS NOT NULL THEN
    v_topic_content := v_topic_content || U&'**\0416\0430\043D\0440:** ' || v_genre_name || E'\n';
  END IF;

  v_topic_content := v_topic_content || U&'**\0413\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0434\043E:** ' || v_voting_ends || E'\n\n' ||
    '---' || E'\n\n' ||
    U&'\042D\0442\043E\0442 \0442\0440\0435\043A \043F\0440\043E\0445\043E\0434\0438\0442 \0433\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0441\043E\043E\0431\0449\0435\0441\0442\0432\0430 \043F\0435\0440\0435\0434 \043E\0442\043F\0440\0430\0432\043A\043E\0439 \043D\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\044E. ' ||
    U&'\041F\043E\0441\043B\0443\0448\0430\0439\0442\0435 \0438 \043E\0446\0435\043D\0438\0442\0435 \2014 \0432\0430\0448 \0433\043E\043B\043E\0441 \0432\043B\0438\044F\0435\0442 \043D\0430 \0438\0442\043E\0433\043E\0432\043E\0435 \0440\0435\0448\0435\043D\0438\0435.' || E'\n\n' ||
    U&'\+01F447' || U&' **\0418\0441\043F\043E\043B\044C\0437\0443\0439\0442\0435 \0432\0438\0434\0436\0435\0442 \043D\0438\0436\0435, \0447\0442\043E\0431\044B \043F\0440\043E\0441\043B\0443\0448\0430\0442\044C \0442\0440\0435\043A \0438 \043F\0440\043E\0433\043E\043B\043E\0441\043E\0432\0430\0442\044C.**' || E'\n\n' ||
    '---' || E'\n\n' ||
    U&'\+01F4CB' || U&' [\041F\0440\0430\0432\0438\043B\0430 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\0438](/distribution-requirements) \00B7 ' ||
    U&'\+01F3A7' || U&' [\041F\0440\043E\0444\0438\043B\044C \0438\0441\043F\043E\043B\043D\0438\0442\0435\043B\044F](/profile/' || v_track.user_id || ')';

  v_slug := lower(v_topic_title);
  v_slug := regexp_replace(v_slug, '[^a-zа-яё0-9\s]', '', 'gi');
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := left(v_slug, 80) || '-' || to_hex(extract(epoch from now())::bigint);

  INSERT INTO public.forum_topics (
    category_id, user_id, title, slug, content, excerpt, track_id, is_pinned, is_hidden
  ) VALUES (
    v_voting_category_id, p_moderator_id, v_topic_title, v_slug, v_topic_content,
    U&'\0422\0440\0435\043A \00AB' || v_track.title || U&'\00BB \043E\0442 ' || v_author_username || U&' \2014 \0433\043E\043B\043E\0441\043E\0432\0430\043D\0438\0435 \0441\043E\043E\0431\0449\0435\0441\0442\0432\0430 \043F\0435\0440\0435\0434 \0434\0438\0441\0442\0440\0438\0431\0443\0446\0438\0435\0439.',
    p_track_id, true, false
  )
  RETURNING id INTO v_topic_id;

  UPDATE public.tracks SET forum_topic_id = v_topic_id WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;

-- 3. Trigger: prevent deletion of the voting category
CREATE OR REPLACE FUNCTION public.protect_voting_category()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_protected_id UUID;
BEGIN
  SELECT value::uuid INTO v_protected_id FROM settings WHERE key = 'forum_voting_category_id';
  IF v_protected_id IS NOT NULL AND OLD.id = v_protected_id THEN
    RAISE EXCEPTION 'Cannot delete the voting category. It is a system category.';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_voting_category ON public.forum_categories;
CREATE TRIGGER trg_protect_voting_category
  BEFORE DELETE ON public.forum_categories
  FOR EACH ROW EXECUTE FUNCTION public.protect_voting_category();
