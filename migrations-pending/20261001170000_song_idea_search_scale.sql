-- Serving path for a catalogue that can grow to hundreds of thousands of cards.
-- User searches stay index-backed and never sort the whole catalogue randomly.

ALTER TABLE public.song_ideas
  ADD COLUMN IF NOT EXISTS discovery_bucket SMALLINT NOT NULL DEFAULT (floor(random() * 64))::smallint
  CHECK (discovery_bucket BETWEEN 0 AND 63);

ALTER TABLE public.song_ideas
  ADD COLUMN IF NOT EXISTS search_document TSVECTOR NOT NULL DEFAULT ''::tsvector;

-- PostgreSQL requires generated expressions to be immutable.  Keep the same
-- indexed document with a trigger, so edits and imports always refresh it.
CREATE OR REPLACE FUNCTION public.refresh_song_idea_search_document()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.search_document := to_tsvector('simple', concat_ws(' ',
    NEW.title, NEW.full_story, NEW.hero_pov, NEW.central_conflict, NEW.emotional_arc,
    NEW.ending_direction, NEW.hook_direction, array_to_string(NEW.genres, ' '),
    array_to_string(NEW.moods, ' '), NEW.energy, array_to_string(NEW.themes, ' ')
  ));
  RETURN NEW;
END;
$$;

UPDATE public.song_ideas
SET search_document = to_tsvector('simple', concat_ws(' ',
  title, full_story, hero_pov, central_conflict, emotional_arc,
  ending_direction, hook_direction, array_to_string(genres, ' '),
  array_to_string(moods, ' '), energy, array_to_string(themes, ' ')
));

DROP TRIGGER IF EXISTS trg_song_idea_search_document ON public.song_ideas;
CREATE TRIGGER trg_song_idea_search_document
BEFORE INSERT OR UPDATE OF title, full_story, hero_pov, central_conflict, emotional_arc,
  ending_direction, hook_direction, genres, moods, energy, themes
ON public.song_ideas
FOR EACH ROW EXECUTE FUNCTION public.refresh_song_idea_search_document();

CREATE INDEX IF NOT EXISTS idx_song_ideas_published_search_document
  ON public.song_ideas USING GIN (search_document) WHERE is_published;
CREATE INDEX IF NOT EXISTS idx_song_ideas_published_bucket_sort
  ON public.song_ideas (discovery_bucket, sort_order, id) WHERE is_published;
CREATE INDEX IF NOT EXISTS idx_song_ideas_published_energy_lower
  ON public.song_ideas (lower(energy)) WHERE is_published;
CREATE INDEX IF NOT EXISTS idx_song_idea_discoveries_user_quota_period
  ON public.song_idea_discoveries (user_id, found_at)
  WHERE used_subscription_quota = true;

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
    OR p_idea.search_document @@ websearch_to_tsquery('simple', trim(p_query));
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
  v_bucket SMALLINT;
  v_query TEXT := NULLIF(trim(p_query), '');
  v_genre TEXT := NULLIF(trim(p_genre), '');
  v_mood TEXT := NULLIF(trim(p_mood), '');
  v_energy TEXT := NULLIF(trim(p_energy), '');
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

  v_bucket := mod(abs(hashtext(v_user::text)), 64)::smallint;

  -- Fast, deterministic personal lane. The index serves the first matching unseen row.
  SELECT i.* INTO v_idea
  FROM public.song_ideas i
  WHERE i.is_published AND i.discovery_bucket = v_bucket
    AND NOT EXISTS (SELECT 1 FROM public.song_idea_discoveries d WHERE d.user_id = v_user AND d.idea_id = i.id)
    AND (v_genre IS NULL OR i.genres @> ARRAY[v_genre])
    AND (v_mood IS NULL OR i.moods @> ARRAY[v_mood])
    AND (v_energy IS NULL OR lower(i.energy) = lower(v_energy))
    AND (v_query IS NULL OR i.search_document @@ websearch_to_tsquery('simple', v_query))
  ORDER BY i.sort_order, i.id LIMIT 1;

  -- Sparse filters can leave a personal lane empty. Fall back without a random full-table sort.
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

  IF NOT FOUND THEN RETURN jsonb_build_object('found', false, 'reason', 'no_matching_ideas'); END IF;
  IF NOT v_used_quota AND v_price > 0 THEN
    UPDATE public.profiles SET balance = balance - v_price
    WHERE user_id = v_user AND balance >= v_price RETURNING balance INTO v_balance;
    IF NOT FOUND THEN RAISE EXCEPTION 'Недостаточно средств на балансе'; END IF;
    INSERT INTO public.balance_transactions (user_id, amount, type, description, balance_before, balance_after)
    VALUES (v_user, -v_price, 'debit', 'Подбор идеи для песни', v_balance + v_price, v_balance);
  END IF;
  INSERT INTO public.song_idea_discoveries (user_id, idea_id, charged_amount, used_subscription_quota)
  VALUES (v_user, v_idea.id, CASE WHEN v_used_quota THEN 0 ELSE v_price END, v_used_quota);
  RETURN jsonb_build_object('found', true, 'idea', to_jsonb(v_idea) - 'search_document',
    'charged_amount', CASE WHEN v_used_quota THEN 0 ELSE v_price END,
    'used_subscription_quota', v_used_quota);
END;
$$;
