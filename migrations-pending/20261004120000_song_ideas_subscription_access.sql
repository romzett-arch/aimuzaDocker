-- Song ideas are a subscription benefit, not a per-search paid service.
-- The access flag lives with the plan so administrators can change it without a deploy.

UPDATE public.subscription_plans
SET service_quotas = jsonb_set(
  COALESCE(service_quotas, '{}'::jsonb),
  '{song_ideas_access}',
  to_jsonb(tier_key <> 'free'),
  true
);

UPDATE public.addon_services
SET price_rub = 0,
    is_active = false,
    description = 'Доступ включён в выбранные тарифы подписки'
WHERE name = 'song_idea_request';

CREATE OR REPLACE FUNCTION public.song_idea_quota(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription RECORD;
  v_enabled BOOLEAN := false;
BEGIN
  IF auth.uid() IS NULL OR (auth.uid() <> p_user_id AND NOT public.is_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT is_enabled INTO v_enabled
  FROM public.song_idea_settings
  WHERE singleton = true;

  SELECT p.name_ru
  INTO v_subscription
  FROM public.user_subscriptions s
  JOIN public.subscription_plans p ON p.id = s.plan_id
  WHERE s.user_id = p_user_id
    AND s.status IN ('active', 'canceled')
    AND s.current_period_end > now()
    AND COALESCE((p.service_quotas ->> 'song_ideas_access')::boolean, false)
  ORDER BY s.current_period_end DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'enabled', COALESCE(v_enabled, false),
    'has_access', FOUND,
    'subscription_name', v_subscription.name_ru
  );
END;
$$;

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
  v_bucket SMALLINT;
  v_query TEXT := NULLIF(trim(p_query), '');
  v_genre TEXT := NULLIF(trim(p_genre), '');
  v_mood TEXT := NULLIF(trim(p_mood), '');
  v_energy TEXT := NULLIF(trim(p_energy), '');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  -- Serialise a user's selections so an idea cannot be issued twice in parallel.
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

  v_bucket := mod(abs(hashtext(v_user::text)), 64)::smallint;

  SELECT i.* INTO v_idea
  FROM public.song_ideas i
  WHERE i.is_published AND i.discovery_bucket = v_bucket
    AND NOT EXISTS (SELECT 1 FROM public.song_idea_discoveries d WHERE d.user_id = v_user AND d.idea_id = i.id)
    AND (v_genre IS NULL OR i.genres @> ARRAY[v_genre])
    AND (v_mood IS NULL OR i.moods @> ARRAY[v_mood])
    AND (v_energy IS NULL OR lower(i.energy) = lower(v_energy))
    AND (v_query IS NULL OR i.search_document @@ websearch_to_tsquery('simple', v_query))
  ORDER BY i.sort_order, i.id LIMIT 1;

  IF NOT FOUND THEN
    SELECT i.* INTO v_idea
    FROM public.song_ideas i
    WHERE i.is_published
      AND NOT EXISTS (SELECT 1 FROM public.song_idea_discoveries d WHERE d.user_id = v_user AND d.idea_id = i.id)
      AND (v_genre IS NULL OR i.genres @> ARRAY[v_genre])
      AND (v_mood IS NULL OR i.moods @> ARRAY[v_mood])
      AND (v_energy IS NULL OR lower(i.energy) = lower(v_energy))
      AND (v_query IS NULL OR i.search_document @@ websearch_to_tsquery('simple', v_query))
    ORDER BY i.sort_order, i.id LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'reason', 'no_matching_ideas');
  END IF;

  INSERT INTO public.song_idea_discoveries (user_id, idea_id, charged_amount, used_subscription_quota)
  VALUES (v_user, v_idea.id, 0, false);

  RETURN jsonb_build_object('found', true, 'idea', to_jsonb(v_idea) - 'search_document');
END;
$$;
