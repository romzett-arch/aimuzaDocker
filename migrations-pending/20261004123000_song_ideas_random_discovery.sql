-- The public flow has one action: receive an unseen random idea.
-- Discovery buckets keep the first lookup index-backed as the catalogue grows.

CREATE OR REPLACE FUNCTION public.find_song_idea(
  p_query TEXT DEFAULT NULL,
  p_genre TEXT DEFAULT NULL,
  p_mood TEXT DEFAULT NULL,
  p_energy TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_settings public.song_idea_settings%ROWTYPE;
  v_idea public.song_ideas%ROWTYPE;
  v_subscription RECORD;
  v_bucket SMALLINT := floor(random() * 64)::smallint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  PERFORM 1 FROM public.profiles WHERE user_id = v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Профиль пользователя не найден'; END IF;

  SELECT * INTO v_settings FROM public.song_idea_settings WHERE singleton = true;
  IF NOT COALESCE(v_settings.is_enabled, false) THEN
    RAISE EXCEPTION 'Функция временно недоступна';
  END IF;

  SELECT p.id
  INTO v_subscription
  FROM public.user_subscriptions s
  JOIN public.subscription_plans p ON p.id = s.plan_id
  WHERE s.user_id = v_user
    AND s.status IN ('active', 'canceled')
    AND s.current_period_end > now()
    AND COALESCE((p.service_quotas ->> 'song_ideas_access')::boolean, false)
  ORDER BY s.current_period_end DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Подбор идей доступен в тарифе с подключённой функцией «Идеи для песен»';
  END IF;

  SELECT i.* INTO v_idea
  FROM public.song_ideas i
  WHERE i.is_published
    AND i.discovery_bucket = v_bucket
    AND NOT EXISTS (
      SELECT 1 FROM public.song_idea_discoveries d
      WHERE d.user_id = v_user AND d.idea_id = i.id
    )
  ORDER BY i.sort_order, i.id
  LIMIT 1;

  -- A randomly selected bucket can be empty after a user has seen many ideas.
  -- Fall back to any unseen published card, still without ever repeating one.
  IF NOT FOUND THEN
    SELECT i.* INTO v_idea
    FROM public.song_ideas i
    WHERE i.is_published
      AND NOT EXISTS (
        SELECT 1 FROM public.song_idea_discoveries d
        WHERE d.user_id = v_user AND d.idea_id = i.id
      )
    ORDER BY i.sort_order, i.id
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'reason', 'no_matching_ideas');
  END IF;

  INSERT INTO public.song_idea_discoveries (user_id, idea_id, charged_amount, used_subscription_quota)
  VALUES (v_user, v_idea.id, 0, false);

  RETURN jsonb_build_object('found', true, 'idea', to_jsonb(v_idea) - 'search_document');
END;
$$;
