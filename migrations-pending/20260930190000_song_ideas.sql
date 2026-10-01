-- Song ideas catalogue: published editorial cards, per-user history and atomic billing.

CREATE TABLE IF NOT EXISTS public.song_idea_settings (
  singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  brief_char_limit INTEGER NOT NULL DEFAULT 1000 CHECK (brief_char_limit BETWEEN 100 AND 5000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.song_idea_settings (singleton)
VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.song_ideas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL CHECK (char_length(trim(title)) BETWEEN 3 AND 160),
  full_story TEXT NOT NULL CHECK (char_length(trim(full_story)) >= 30),
  hero_pov TEXT NOT NULL,
  central_conflict TEXT NOT NULL,
  emotional_arc TEXT NOT NULL,
  ending_direction TEXT NOT NULL,
  hook_direction TEXT NOT NULL,
  genres TEXT[] NOT NULL DEFAULT '{}',
  moods TEXT[] NOT NULL DEFAULT '{}',
  energy TEXT NOT NULL DEFAULT '',
  themes TEXT[] NOT NULL DEFAULT '{}',
  generator_brief TEXT NOT NULL,
  is_published BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_song_ideas_published_sort
  ON public.song_ideas (is_published, sort_order, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_song_ideas_genres ON public.song_ideas USING GIN (genres);
CREATE INDEX IF NOT EXISTS idx_song_ideas_moods ON public.song_ideas USING GIN (moods);
CREATE INDEX IF NOT EXISTS idx_song_ideas_themes ON public.song_ideas USING GIN (themes);

CREATE TABLE IF NOT EXISTS public.song_idea_discoveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  idea_id UUID NOT NULL REFERENCES public.song_ideas(id) ON DELETE CASCADE,
  found_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at TIMESTAMPTZ,
  used_at TIMESTAMPTZ,
  charged_amount INTEGER NOT NULL DEFAULT 0 CHECK (charged_amount >= 0),
  used_subscription_quota BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, idea_id)
);

CREATE INDEX IF NOT EXISTS idx_song_idea_discoveries_user_found
  ON public.song_idea_discoveries (user_id, found_at DESC);
CREATE INDEX IF NOT EXISTS idx_song_idea_discoveries_idea
  ON public.song_idea_discoveries (idea_id);

ALTER TABLE public.song_idea_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.song_ideas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.song_idea_discoveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Song idea settings are readable" ON public.song_idea_settings;
CREATE POLICY "Song idea settings are readable" ON public.song_idea_settings
  FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage song idea settings" ON public.song_idea_settings;
CREATE POLICY "Admins manage song idea settings" ON public.song_idea_settings
  FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Published song ideas are readable" ON public.song_ideas;
CREATE POLICY "Published song ideas are readable" ON public.song_ideas
  FOR SELECT USING (is_published OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS "Admins manage song ideas" ON public.song_ideas;
CREATE POLICY "Admins manage song ideas" ON public.song_ideas
  FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users read own song idea discoveries" ON public.song_idea_discoveries;
CREATE POLICY "Users read own song idea discoveries" ON public.song_idea_discoveries
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.song_idea_quota(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription RECORD;
  v_quota INTEGER := 0;
  v_used INTEGER := 0;
  v_price INTEGER := 0;
  v_enabled BOOLEAN := false;
BEGIN
  IF auth.uid() IS NULL OR (auth.uid() <> p_user_id AND NOT public.is_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT is_enabled INTO v_enabled FROM public.song_idea_settings WHERE singleton = true;
  SELECT COALESCE(price_rub, 0)::INTEGER INTO v_price
  FROM public.addon_services WHERE name = 'song_idea_request' LIMIT 1;

  SELECT s.id, s.current_period_start, s.current_period_end, p.name_ru, p.service_quotas
  INTO v_subscription
  FROM public.user_subscriptions s
  JOIN public.subscription_plans p ON p.id = s.plan_id
  WHERE s.user_id = p_user_id
    AND s.status IN ('active', 'canceled')
    AND s.current_period_end > now()
  ORDER BY s.current_period_end DESC
  LIMIT 1;

  IF FOUND THEN
    v_quota := GREATEST(0, COALESCE((v_subscription.service_quotas ->> 'song_ideas')::INTEGER, 0));
    SELECT count(*) INTO v_used
    FROM public.song_idea_discoveries
    WHERE user_id = p_user_id
      AND used_subscription_quota = true
      AND found_at >= v_subscription.current_period_start
      AND found_at < v_subscription.current_period_end;
  END IF;

  RETURN jsonb_build_object(
    'enabled', COALESCE(v_enabled, false),
    'price', COALESCE(v_price, 0),
    'subscription_name', v_subscription.name_ru,
    'quota_total', v_quota,
    'quota_used', v_used,
    'quota_remaining', GREATEST(v_quota - v_used, 0),
    'uses_paid_request', GREATEST(v_quota - v_used, 0) = 0
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
  v_quota INTEGER := 0;
  v_used INTEGER := 0;
  v_price INTEGER := 0;
  v_balance INTEGER;
  v_used_quota BOOLEAN := false;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;

  -- Locks one user flow, preventing duplicate cards, quota bypass and double debit.
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
    AND (NULLIF(trim(p_query), '') IS NULL OR concat_ws(' ', i.title, i.full_story, i.hero_pov, i.central_conflict, i.emotional_arc, i.hook_direction, array_to_string(i.themes, ' ')) ILIKE '%' || trim(p_query) || '%')
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

CREATE OR REPLACE FUNCTION public.accept_song_idea(p_idea_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.song_idea_discoveries SET accepted_at = COALESCE(accepted_at, now())
  WHERE user_id = auth.uid() AND idea_id = p_idea_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Идея не найдена в вашей истории'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_song_idea_history()
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data ->> 'found_at') DESC), '[]'::jsonb)
  FROM (
    SELECT to_jsonb(d) || jsonb_build_object('idea', to_jsonb(i)) AS row_data
    FROM public.song_idea_discoveries d
    JOIN public.song_ideas i ON i.id = d.idea_id
    WHERE d.user_id = auth.uid()
  ) history;
$$;

GRANT EXECUTE ON FUNCTION public.song_idea_quota(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_song_idea(TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_song_idea(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_song_idea_history() TO authenticated;

INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES ('song_idea_request', 'Подбор идеи для песни', 'Одна новая идея из каталога', 10, 'lightbulb', true, 85)
ON CONFLICT (name) DO NOTHING;

-- Default quotas are deliberately conservative and are editable per plan in the admin UI.
UPDATE public.subscription_plans
SET service_quotas = jsonb_set(COALESCE(service_quotas, '{}'::jsonb), '{song_ideas}',
  to_jsonb(CASE tier_key WHEN 'creator' THEN 5 WHEN 'pro' THEN 10 WHEN 'label' THEN 20 ELSE 0 END), true);

INSERT INTO public.song_ideas (
  title, full_story, hero_pov, central_conflict, emotional_arc, ending_direction, hook_direction,
  genres, moods, energy, themes, generator_brief, is_published, sort_order
) VALUES
('Последний рейс', 'Ночной водитель везёт пассажира, который неожиданно оказывается его будущей версией. До рассвета он должен решить, повторит ли старую ошибку.', 'От первого лица, усталый ночной водитель.', 'Страх снова выбрать работу вместо близкого человека.', 'От оцепенения к решимости.', 'Герой сворачивает с привычного маршрута к дому.', 'Припев о последнем рейсе до рассвета.', ARRAY['Поп','Синтвейв'], ARRAY['Ностальгия','Надежда'], 'Средняя', ARRAY['ночь','выбор','дорога'], 'Ночной синтвейв-поп: водитель встречает будущего себя и выбирает дом вместо привычного бегства. Ностальгия, нарастающая надежда, большой хук «последний рейс до рассвета».', true, 1),
('Квартира без эха', 'После расставания героиня замечает, что пустая квартира перестала повторять её слова. Она учится говорить вслух то, что раньше прятала.', 'От первого лица, молодая женщина.', 'Одиночество оказывается честнее прежних отношений.', 'От боли к освобождению.', 'В финале квартира снова возвращает ей голос.', 'Хук: «в квартире без эха я слышу себя».', ARRAY['Инди-поп'], ARRAY['Грусть','Освобождение'], 'Низкая', ARRAY['расставание','дом','самопринятие'], 'Инди-поп о девушке после расставания: в тихой квартире она наконец слышит себя. Интимные куплеты, освобождающий припев «в квартире без эха я слышу себя».', true, 2),
('Чужой район', 'Парень возвращается в родной город и идёт по знакомым дворам, где всё изменилось. Он понимает, что чужим стал не город, а он сам.', 'От первого лица, вернувшийся домой герой.', 'Невозможно вернуться в прежнюю версию себя.', 'От отчуждения к тёплому принятию перемен.', 'Он оставляет ключ от старого подъезда и идёт дальше.', 'Хук о чужом районе, который помнит его имя.', ARRAY['Рок','Альтернатива'], ARRAY['Тоска','Сила'], 'Высокая', ARRAY['город','возвращение','прошлое'], 'Энергичный альтернативный рок о возвращении в изменившийся родной район. Герой принимает перемены; мощный припев «чужой район помнит моё имя».', true, 3),
('Письмо в черновиках', 'Героиня годами хранит несданное письмо отцу. В день его юбилея она не отправляет текст, а приезжает и читает письмо вслух.', 'От первого лица, взрослая дочь.', 'Страх быть отвергнутой отцом.', 'От сдержанности к уязвимости.', 'Отец молча обнимает её после последней строки.', 'Хук: «я нажимаю отправить голосом».', ARRAY['Баллада','Поп'], ARRAY['Нежность','Светлая грусть'], 'Низкая', ARRAY['семья','прощение','письмо'], 'Трогательная поп-баллада о дочери, которая вместо отправки старого письма читает его отцу вслух. Нежный вокал, кульминация в припеве «отправить голосом».', true, 4),
('Неоновый сад', 'Двое подростков тайком выращивают растения на крыше торгового центра. Когда крышу закрывают, они устраивают там последнюю ночную вечеринку.', 'От первого лица, один из друзей.', 'Маленький живой мир против бездушного города.', 'От игры к дерзкому протесту.', 'После вечеринки они раздают семена незнакомцам.', 'Хук: «мы посадим свет в неоновый сад».', ARRAY['Электропоп','Хип-хоп'], ARRAY['Драйв','Радость'], 'Высокая', ARRAY['дружба','город','свобода'], 'Драйвовый электропоп с речитативом: друзья защищают тайный сад на крыше. Яркий хук «посадим свет в неоновый сад», городская энергия и свобода.', true, 5),
('Семь минут тишины', 'Музыкант перед выходом на сцену теряет слух на несколько минут. В этой тишине он вспоминает, зачем вообще начал писать песни.', 'От первого лица, музыкант.', 'Успех заглушил любовь к музыке.', 'От паники к подлинному вдохновению.', 'Он выходит на сцену и начинает с одного честного аккорда.', 'Хук: «семь минут тишины громче оваций».', ARRAY['Поп-рок'], ARRAY['Напряжение','Вдохновение'], 'Средняя', ARRAY['музыка','сцена','призвание'], 'Поп-рок о музыканте перед сценой, который в внезапной тишине возвращает себе смысл творчества. Нарастающий припев «семь минут тишины громче оваций».', true, 6),
('Река помнит', 'Старый рыбак каждый год отпускает одну пойманную рыбу в память о брате. В этот раз с ним идёт племянник, который не знает этой истории.', 'От первого лица, пожилой рыбак.', 'Как передать память, не превращая её в тяжесть.', 'От молчания к доверию.', 'Племянник сам выпускает рыбу в воду.', 'Хук о реке, которая помнит имена.', ARRAY['Фолк'], ARRAY['Спокойствие','Светлая грусть'], 'Низкая', ARRAY['память','семья','природа'], 'Тёплая фолк-песня о рыбаке, памяти о брате и племяннике. Акустика, вода и спокойный хук «река помнит наши имена».', true, 7),
('После сигнала', 'Девушка записывает голосовые сообщения человеку, который давно не отвечает. Однажды после сигнала она слышит собственный голос и понимает, что говорит с собой.', 'От первого лица, девушка.', 'Зависимость от отсутствующего ответа.', 'От ожидания к возвращению себе.', 'Последнее сообщение она оставляет себе на завтра.', 'Хук: «после сигнала остаюсь я».', ARRAY['R&B','Поп'], ARRAY['Меланхолия','Уверенность'], 'Средняя', ARRAY['голос','ожидание','самоценность'], 'Современный R&B-поп о голосовых сообщениях без ответа и возвращении к себе. Мягкий грув, интимные куплеты, хук «после сигнала остаюсь я».', true, 8),
('Северный ветер', 'Команда маленького корабля застревает во льдах, и капитан скрывает страх. Юный матрос первым предлагает рискованный путь через шторм.', 'От первого лица, молодой матрос.', 'Нужно заслужить право быть услышанным.', 'От робости к лидерству.', 'Корабль выходит к чистой воде на рассвете.', 'Хук: «северный ветер знает дорогу».', ARRAY['Эпик-рок'], ARRAY['Смелость','Напряжение'], 'Высокая', ARRAY['море','команда','смелость'], 'Эпичный рок о молодом матросе во льдах, который находит путь для команды. Барабаны, широкий припев «северный ветер знает дорогу».', true, 9),
('Танец на кухне', 'Пара после тяжёлой ссоры случайно слышит старую песню из первого свидания. Они танцуют среди посуды, не решив всех проблем, но решив остаться.', 'От первого лица, один из партнёров.', 'Любовь требует выбора после конфликта.', 'От отчуждения к хрупкой близости.', 'Утром они вместе моют посуду и смеются.', 'Хук: «пока мир молчит, мы танцуем на кухне».', ARRAY['Соул','Поп'], ARRAY['Тепло','Надежда'], 'Средняя', ARRAY['любовь','ссора','примирение'], 'Тёплый соул-поп о паре после ссоры, которая танцует на кухне под песню первого свидания. Живой грув и припев «мы танцуем на кухне».', true, 10)
ON CONFLICT DO NOTHING;
