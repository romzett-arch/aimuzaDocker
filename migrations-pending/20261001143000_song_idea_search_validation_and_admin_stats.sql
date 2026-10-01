-- Complete song-idea search coverage, protect published cards and expose admin-only funnel stats.

CREATE OR REPLACE FUNCTION public.song_idea_matches_search(
  p_idea public.song_ideas,
  p_query TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT NULLIF(trim(p_query), '') IS NULL
    OR concat_ws(
      ' ',
      p_idea.title,
      p_idea.full_story,
      p_idea.hero_pov,
      p_idea.central_conflict,
      p_idea.emotional_arc,
      p_idea.ending_direction,
      p_idea.hook_direction,
      array_to_string(p_idea.genres, ' '),
      array_to_string(p_idea.moods, ' '),
      p_idea.energy,
      array_to_string(p_idea.themes, ' ')
    ) ILIKE '%' || trim(p_query) || '%';
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
  v_quota INTEGER := 0;
  v_used INTEGER := 0;
  v_price INTEGER := 0;
  v_balance INTEGER;
  v_used_quota BOOLEAN := false;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  PERFORM 1 FROM public.profiles WHERE user_id = v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Профиль пользователя не найден'; END IF;

  SELECT * INTO v_settings FROM public.song_idea_settings WHERE singleton = true;
  IF NOT COALESCE(v_settings.is_enabled, false) THEN RAISE EXCEPTION 'Функция временно недоступна'; END IF;

  SELECT COALESCE(price_rub, 0)::INTEGER INTO v_price
  FROM public.addon_services WHERE name = 'song_idea_request' AND is_active = true LIMIT 1;
  IF v_price IS NULL OR v_price < 0 THEN RAISE EXCEPTION 'Стоимость услуги не настроена'; END IF;

  SELECT s.id, s.current_period_start, s.current_period_end, p.service_quotas
  INTO v_subscription
  FROM public.user_subscriptions s JOIN public.subscription_plans p ON p.id = s.plan_id
  WHERE s.user_id = v_user AND s.status IN ('active', 'canceled') AND s.current_period_end > now()
  ORDER BY s.current_period_end DESC LIMIT 1;

  IF FOUND THEN
    v_quota := GREATEST(0, COALESCE((v_subscription.service_quotas ->> 'song_ideas')::INTEGER, 0));
    SELECT count(*) INTO v_used FROM public.song_idea_discoveries
    WHERE user_id = v_user AND used_subscription_quota = true
      AND found_at >= v_subscription.current_period_start AND found_at < v_subscription.current_period_end;
    v_used_quota := v_used < v_quota;
  END IF;

  SELECT i.* INTO v_idea
  FROM public.song_ideas i
  WHERE i.is_published
    AND NOT EXISTS (SELECT 1 FROM public.song_idea_discoveries d WHERE d.user_id = v_user AND d.idea_id = i.id)
    AND (NULLIF(trim(p_genre), '') IS NULL OR EXISTS (SELECT 1 FROM unnest(i.genres) x WHERE lower(x) = lower(p_genre)))
    AND (NULLIF(trim(p_mood), '') IS NULL OR EXISTS (SELECT 1 FROM unnest(i.moods) x WHERE lower(x) = lower(p_mood)))
    AND (NULLIF(trim(p_energy), '') IS NULL OR lower(i.energy) = lower(p_energy))
    AND public.song_idea_matches_search(i, p_query)
  ORDER BY random()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'reason', 'no_matching_ideas');
  END IF;

  IF NOT v_used_quota AND v_price > 0 THEN
    UPDATE public.profiles SET balance = balance - v_price
    WHERE user_id = v_user AND balance >= v_price RETURNING balance INTO v_balance;
    IF NOT FOUND THEN RAISE EXCEPTION 'Недостаточно средств на балансе'; END IF;
    INSERT INTO public.balance_transactions (user_id, amount, type, description, balance_before, balance_after)
    VALUES (v_user, -v_price, 'debit', 'Подбор идеи для песни', v_balance + v_price, v_balance);
  END IF;

  INSERT INTO public.song_idea_discoveries (user_id, idea_id, charged_amount, used_subscription_quota)
  VALUES (v_user, v_idea.id, CASE WHEN v_used_quota THEN 0 ELSE v_price END, v_used_quota);

  RETURN jsonb_build_object('found', true, 'idea', to_jsonb(v_idea), 'charged_amount', CASE WHEN v_used_quota THEN 0 ELSE v_price END, 'used_subscription_quota', v_used_quota);
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_published_song_idea_completeness()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.is_published AND (
    trim(NEW.title) = '' OR trim(NEW.full_story) = '' OR trim(NEW.hero_pov) = ''
    OR trim(NEW.central_conflict) = '' OR trim(NEW.emotional_arc) = ''
    OR trim(NEW.ending_direction) = '' OR trim(NEW.hook_direction) = ''
    OR trim(NEW.energy) = '' OR trim(NEW.generator_brief) = ''
    OR COALESCE(cardinality(NEW.genres), 0) = 0 OR COALESCE(cardinality(NEW.moods), 0) = 0
    OR COALESCE(cardinality(NEW.themes), 0) = 0
    OR EXISTS (SELECT 1 FROM unnest(NEW.genres) AS value WHERE trim(value) = '')
    OR EXISTS (SELECT 1 FROM unnest(NEW.moods) AS value WHERE trim(value) = '')
    OR EXISTS (SELECT 1 FROM unnest(NEW.themes) AS value WHERE trim(value) = '')
  ) THEN
    RAISE EXCEPTION 'Нельзя опубликовать неполную карточку идеи';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_song_idea_publish_completeness ON public.song_ideas;
CREATE TRIGGER trg_song_idea_publish_completeness
BEFORE INSERT OR UPDATE OF is_published, title, full_story, hero_pov, central_conflict,
  emotional_arc, ending_direction, hook_direction, genres, moods, energy, themes, generator_brief
ON public.song_ideas
FOR EACH ROW EXECUTE FUNCTION public.enforce_published_song_idea_completeness();

CREATE OR REPLACE VIEW public.song_idea_admin_stats
WITH (security_invoker = true)
AS
SELECT i.id AS idea_id,
       count(d.id)::integer AS found_count,
       count(d.accepted_at) FILTER (WHERE d.accepted_at IS NOT NULL)::integer AS accepted_count,
       count(d.used_at) FILTER (WHERE d.used_at IS NOT NULL)::integer AS successful_generation_count
FROM public.song_ideas i
LEFT JOIN public.song_idea_discoveries d ON d.idea_id = i.id
WHERE public.is_admin(auth.uid())
GROUP BY i.id;

GRANT SELECT ON public.song_idea_admin_stats TO authenticated;
