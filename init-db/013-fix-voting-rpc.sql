-- Drop old function overloads with wrong signatures
DROP FUNCTION IF EXISTS public.send_track_to_voting(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.create_voting_forum_topic(uuid, text, text);

-- Fix send_track_to_voting: match frontend signature (p_track_id, p_duration_days, p_voting_type)
-- Frontend sends: { p_track_id: trackId, p_duration_days: durationDays || null, p_voting_type: votingType }
-- Old function expected (p_track_id, p_user_id, p_voting_type) — WRONG
CREATE OR REPLACE FUNCTION public.send_track_to_voting(
  p_track_id uuid,
  p_duration_days int DEFAULT NULL,
  p_voting_type text DEFAULT 'public'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_duration interval;
BEGIN
  -- Calculate duration
  IF p_duration_days IS NOT NULL AND p_duration_days > 0 THEN
    v_duration := (p_duration_days || ' days')::interval;
  ELSIF p_voting_type = 'internal' THEN
    v_duration := interval '1 day';
  ELSE
    v_duration := interval '7 days';
  END IF;

  UPDATE public.tracks
  SET moderation_status = 'voting',
      voting_started_at = now(),
      voting_ends_at = now() + v_duration,
      voting_type = p_voting_type,
      voting_likes_count = 0,
      voting_dislikes_count = 0,
      voting_result = NULL
  WHERE id = p_track_id;

  RETURN FOUND;
END;
$function$;

-- Fix create_voting_forum_topic: match frontend signature (p_track_id, p_moderator_id)
-- Frontend sends: { p_track_id: trackId, p_moderator_id: user.id }
-- Old function expected (p_track_id, p_title, p_content) — WRONG
CREATE OR REPLACE FUNCTION public.create_voting_forum_topic(
  p_track_id uuid,
  p_moderator_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_topic_id uuid;
  v_track record;
  v_category_id uuid;
  v_title text;
  v_content text;
BEGIN
  -- Get track info
  SELECT id, title, user_id, description, cover_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found';
  END IF;

  -- Find or create a voting category
  SELECT id INTO v_category_id
  FROM public.forum_categories
  WHERE slug = 'news'
  LIMIT 1;

  -- If no category found, use the first one
  IF v_category_id IS NULL THEN
    SELECT id INTO v_category_id
    FROM public.forum_categories
    ORDER BY sort_order LIMIT 1;
  END IF;

  -- Build title and content
  v_title := '🗳️ Голосование: ' || COALESCE(v_track.title, 'Без названия');
  v_content := '**Трек отправлен на публичное голосование.**' || E'\n\n' ||
    'Послушайте и проголосуйте — ваш голос важен!' || E'\n\n' ||
    '🎵 **' || COALESCE(v_track.title, 'Без названия') || '**';

  -- Create pinned topic
  INSERT INTO public.forum_topics (
    user_id, category_id, title, content, is_pinned, is_locked, tags
  )
  VALUES (
    p_moderator_id, v_category_id, v_title, v_content, true, false, ARRAY['voting']
  )
  RETURNING id INTO v_topic_id;

  -- Link topic to track
  UPDATE public.tracks
  SET forum_topic_id = v_topic_id
  WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$function$;
