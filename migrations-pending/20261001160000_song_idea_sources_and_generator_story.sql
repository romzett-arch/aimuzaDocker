-- Closed editorial provenance registry and the short storyline used by the lyric generator.

ALTER TABLE public.song_ideas ADD COLUMN IF NOT EXISTS generator_story TEXT;
UPDATE public.song_ideas
SET generator_story = left(trim(generator_brief), 200)
WHERE generator_story IS NULL OR trim(generator_story) = '';
ALTER TABLE public.song_ideas ALTER COLUMN generator_story SET NOT NULL;
ALTER TABLE public.song_ideas DROP CONSTRAINT IF EXISTS song_ideas_generator_story_length;
ALTER TABLE public.song_ideas ADD CONSTRAINT song_ideas_generator_story_length
  CHECK (char_length(trim(generator_story)) BETWEEN 10 AND 200);

CREATE OR REPLACE FUNCTION public.enforce_song_idea_generator_story_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF char_length(trim(NEW.generator_story)) > 200 THEN
    RAISE EXCEPTION 'Сюжет для генератора не может быть длиннее 200 символов';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_song_idea_generator_story_limit ON public.song_ideas;
CREATE TRIGGER trg_song_idea_generator_story_limit
  BEFORE INSERT OR UPDATE OF generator_story ON public.song_ideas
  FOR EACH ROW EXECUTE FUNCTION public.enforce_song_idea_generator_story_limit();

CREATE TABLE IF NOT EXISTS public.song_idea_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idea_id UUID NOT NULL UNIQUE REFERENCES public.song_ideas(id) ON DELETE CASCADE,
  original_key TEXT NOT NULL UNIQUE CHECK (char_length(trim(original_key)) >= 5),
  author_name TEXT NOT NULL,
  original_title TEXT NOT NULL,
  original_language TEXT NOT NULL,
  origin_country TEXT,
  original_year INTEGER,
  source_url TEXT NOT NULL,
  rights_check TEXT NOT NULL,
  music_adaptations JSONB NOT NULL DEFAULT '[]'::jsonb,
  source_synopsis TEXT NOT NULL,
  main_image TEXT NOT NULL,
  editorial_status TEXT NOT NULL DEFAULT 'accepted'
    CHECK (editorial_status IN ('candidate', 'accepted', 'rejected', 'legacy_unverified')),
  editor_note TEXT,
  verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_song_idea_sources_status ON public.song_idea_sources(editorial_status, verified_at DESC);
ALTER TABLE public.song_idea_sources ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage hidden song idea sources" ON public.song_idea_sources;
CREATE POLICY "Admins manage hidden song idea sources" ON public.song_idea_sources
  FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

INSERT INTO public.song_ideas (
  title, full_story, hero_pov, central_conflict, emotional_arc, ending_direction, hook_direction,
  genres, moods, energy, themes, generator_brief, generator_story, is_published, sort_order
) VALUES
('Голос из кузницы', 'Одинокий кузнец поднимает детей после смерти жены. В воскресенье он слышит, как дочь поёт, и понимает: работа не заменяет горе, но помогает семье жить дальше.', 'От первого лица, отец и мастер.', 'Нужно быть сильным для детей, не отрицая собственную утрату.', 'От сдержанной боли к тёплой благодарности.', 'Отец впервые говорит дочери, что её голос возвращает дому свет.', 'Удар молота превращается в ритм припева.', ARRAY['Фолк','Поп'], ARRAY['Тепло','Светлая грусть'], 'Средняя', ARRAY['семья','работа','память'], 'Тёплая фолк-поп история об отце-кузнеце: после утраты он растит детей и слышит надежду в голосе дочери.', 'Одинокий кузнец растит детей после смерти жены и слышит её голос в пении дочери.', true, 101),
('На краю кровати', 'После резкого наказания отец ночью видит, как сын окружил себя маленькими сокровищами, чтобы не бояться. Отец понимает, что его гнев оказался больше проступка.', 'От первого лица, отец.', 'Гордость мешает вовремя попросить прощения у ребёнка.', 'От раздражения к вине и нежности.', 'Утром отец начинает разговор первым.', 'Маленькая коробка у кровати как образ детского мира.', ARRAY['Баллада','Поп'], ARRAY['Нежность','Вина'], 'Низкая', ARRAY['семья','прощение','детство'], 'Интимная баллада об отце, который после ссоры с сыном понимает цену жёстких слов и выбирает попросить прощения.', 'Отец после ссоры замечает, как сын утешает себя игрушками, и решает первым попросить прощения.', true, 102),
('Скажи ей сам', 'После потери жены суровый мужчина просит лучшего друга поговорить с девушкой от его имени. Девушка слышит чужие слова и мягко возвращает посланника к его собственным чувствам.', 'От первого лица, застенчивый друг.', 'Нельзя строить любовь на чужом голосе и поручениях.', 'От неловкости к честному признанию.', 'Друг перестаёт быть посредником и говорит о себе.', 'Хук о словах, которые надо сказать самому.', ARRAY['Поп','Инди-поп'], ARRAY['Ирония','Надежда'], 'Средняя', ARRAY['любовь','дружба','выбор'], 'Лёгкий поп о любовном посреднике, который внезапно понимает: говорить чужими словами нельзя, а свои чувства давно рядом.', 'Друг приходит свататься за другого мужчину, но девушка просит его наконец сказать правду от себя.', true, 103),
('Ещё один поворот', 'После отказа герой просит любимую не вернуться к нему, а провести вместе один последний вечер. Во время поездки он учится не торговаться с её решением и ценить момент.', 'От первого лица, отвергнутый герой.', 'Как попрощаться без давления и сохранить достоинство.', 'От отчаяния к спокойному принятию.', 'На последнем повороте герой отпускает её руку.', 'Один поворот дороги как последняя возможность сказать спасибо.', ARRAY['Инди-поп','Баллада'], ARRAY['Светлая грусть','Нежность'], 'Средняя', ARRAY['любовь','расставание','дорога'], 'Инди-поп о последней совместной поездке после расставания: герой перестаёт уговаривать и выбирает благодарность.', 'После отказа герой просит только одну последнюю поездку и учится отпускать без давления.', true, 104),
('Не стучать в окно', 'Моряк после долгого исчезновения возвращается домой и видит, что любимая женщина обрела новую семью. Он должен решить, заявить о себе или сохранить её покой.', 'От первого лица, вернувшийся моряк.', 'Право на прошлое сталкивается с чужим настоящим счастьем.', 'От надежды к горькой щедрости.', 'Он уходит, не разрушив дом, который когда-то считал своим.', 'Свет в окне, в которое он решает не стучать.', ARRAY['Баллада','Фолк'], ARRAY['Тоска','Благородство'], 'Низкая', ARRAY['любовь','семья','возвращение'], 'Баллада о моряке, который после долгого отсутствия видит новую семью любимой и выбирает не разрушать её счастье.', 'Вернувшийся моряк видит, что любимая счастлива с другой семьёй, и решает не стучать в их окно.', true, 105),
('Шёлковое пальто', 'Две подруги встречаются после долгой разлуки. Одна выглядит безупречно успешной, но разговор постепенно раскрывает цену её городского блеска и чужих ожиданий.', 'От первого лица, подруга-наблюдательница.', 'Внешний успех не даёт права обесценивать цену чужого выбора.', 'От зависти к сложному сочувствию.', 'Подруги расходятся без простого ответа, но без осуждения.', 'Шёлковое пальто как витрина новой жизни.', ARRAY['Поп','Соул'], ARRAY['Ирония','Меланхолия'], 'Средняя', ARRAY['дружба','город','выбор'], 'Современный поп о встрече двух подруг: за глянцевым успехом одной скрывается цена, о которой неудобно говорить.', 'Две подруги встречаются в городе, и за дорогим пальто одной открывается цена её новой жизни.', true, 106),
('Четырнадцать лет', 'Человек берёт щенка, понимая, что однажды придётся прощаться. Вместо страха он выбирает прожить эту дружбу внимательно: прогулки, ожидание у двери и обычные дни.', 'От первого лица, хозяин собаки.', 'Любовь к животному требует принять неизбежность короткой жизни.', 'От страха потери к благодарности за близость.', 'Герой идёт на привычную прогулку и бережёт память без надрыва.', 'Годы, которые измеряются прогулками и возвращениями домой.', ARRAY['Фолк','Поп'], ARRAY['Нежность','Светлая грусть'], 'Низкая', ARRAY['животные','дружба','память'], 'Нежная фолк-поп песня о человеке и собаке: он знает, что дружба не вечна, но выбирает прожить каждый день рядом.', 'Человек берёт щенка, зная о короткой жизни собаки, и выбирает не бояться этой любви.', true, 107),
('Трей нырнул первым', 'Собака бросается в воду и спасает ребёнка, пока взрослые спорят, кто должен рисковать. После спасения люди видят в герое не живое существо, а удобный объект для опытов.', 'От первого лица, очевидец.', 'Искренняя верность сталкивается с холодной человеческой выгодой.', 'От тревоги к восхищению и гневу.', 'Очевидец уводит собаку домой, выбирая защитить спасителя.', 'Первым в воду ныряет тот, кого люди считали просто животным.', ARRAY['Поп-рок','Рок'], ARRAY['Напряжение','Вдохновение'], 'Высокая', ARRAY['животные','спасение','верность'], 'Энергичный поп-рок о собаке, которая спасает ребёнка раньше взрослых, и о человеке, который встаёт на её защиту.', 'Собака спасает ребёнка из воды, а очевидец защищает героя от людей, желающих использовать его.', true, 108),
('Не догнать тройку', 'Девушка видит, как мимо проносится чужая свобода, и впервые понимает, что окружающие уже написали для неё тяжёлый сценарий. Она ищет в себе смелость не соглашаться молча.', 'От первого лица, молодая женщина.', 'Навязанная судьба против права выбрать собственную жизнь.', 'От тревоги к внутреннему сопротивлению.', 'Она не бежит за чужой каретой, а делает первый шаг в свою сторону.', 'Образ быстрой тройки, которую нельзя догнать чужими правилами.', ARRAY['Фолк','Поп-рок'], ARRAY['Тоска','Сила'], 'Средняя', ARRAY['выбор','свобода','дорога'], 'Фолк-поп-рок о девушке, которая видит чужую свободу и решает перестать жить по навязанному сценарию.', 'Девушка видит проезжающую чужую свободу и решает не соглашаться на навязанную судьбу.', true, 109),
('Не одна на этой дороге', 'Молодую женщину бросают, а окружающие вместо помощи делают её виноватой. Она проходит через стыд и одиночество, но находит людей, которые помогают ей сохранить себя и ребёнка.', 'От первого лица, молодая мать.', 'Предательство и общественное осуждение против права на поддержку.', 'От боли и изоляции к силе и солидарности.', 'Героиня выбирает жизнь и помощь, а не чужой приговор.', 'Дорога, на которой рядом появляются те, кто не отворачивается.', ARRAY['Баллада','Поп'], ARRAY['Боль','Сила'], 'Средняя', ARRAY['любовь','семья','поддержка'], 'Современная баллада о молодой матери, которую бросили и осудили, но которая находит поддержку и выбирает жить дальше.', 'Брошенная молодая мать проходит через осуждение и находит людей, которые помогают ей сохранить себя.', true, 110)
ON CONFLICT DO NOTHING;

INSERT INTO public.song_idea_sources (
  idea_id, original_key, author_name, original_title, original_language, origin_country, original_year,
  source_url, rights_check, music_adaptations, source_synopsis, main_image, editorial_status, editor_note
)
SELECT i.id, s.original_key, s.author_name, s.original_title, s.original_language, s.origin_country, s.original_year,
  s.source_url, s.rights_check, s.music_adaptations::jsonb, s.source_synopsis, s.main_image, 'accepted', s.editor_note
FROM (VALUES
  ('Голос из кузницы','henry-wadsworth-longfellow|the-village-blacksmith','Henry W. Longfellow','The Village Blacksmith','English','USA',1842,'https://www.lieder.net/lieder/get_text.html?TextId=21972','Автор умер в 1882 году; оригинал XIX века. Проверка для редакционного использования: public domain.','["Многочисленные вокальные и хоровые обработки; перечень в LiederNet"]','Кузнец растит детей после смерти жены; пение дочери возвращает ему память и тепло.','Кузница и голос дочери','Текст имеет известные обработки; используем только независимый сюжет, без строк.'),
  ('На краю кровати','coventry-patmore|the-toys','Coventry Patmore','The Toys','English','United Kingdom',1877,'https://www.lieder.net/lieder/get_text.html?TextId=42726','Автор умер в 1896 году; оригинал XIX века. Проверка для редакционного использования: public domain.','["John H. Ashton, The toys, 1973"]','Отец после наказания ребёнка видит его маленькие утешения и осознаёт свою жестокость.','Коробка с детскими сокровищами','Не переносить религиозные формулировки и строки оригинала.'),
  ('Скажи ей сам','henry-wadsworth-longfellow|the-courtship-of-miles-standish','Henry W. Longfellow','The Courtship of Miles Standish','English','USA',1858,'https://en.wikisource.org/wiki/The_Courtship_of_Miles_Standish/Miles_Standish','Автор умер в 1882 году; оригинал XIX века. Проверка для редакционного использования: public domain.','[]','Друг должен свататься за вдовца, но девушка раскрывает неискренность посредничества.','Слова, сказанные чужим голосом','Историческая рамка поэмы художественная; берём только бытовой конфликт.'),
  ('Ещё один поворот','robert-browning|the-last-ride-together','Robert Browning','The Last Ride Together','English','United Kingdom',1855,'https://en.wikisource.org/wiki/Men_and_Women_(Browning)/Volume_1/The_Last_Ride_Together)','Автор умер в 1889 году; оригинал XIX века. Проверка для редакционного использования: public domain.','[]','После отказа герой просит последний совместный путь и учится принять расставание.','Последний поворот дороги','Не использовать оригинальные обращения и образы дословно.'),
  ('Не стучать в окно','alfred-tennyson|enoch-arden','Alfred Tennyson','Enoch Arden','English','United Kingdom',1864,'https://en.wikisource.org/wiki/Enoch_Arden,_etc','Автор умер в 1892 году; оригинал XIX века. Проверка для редакционного использования: public domain.','["Richard Strauss, Enoch Arden; также переводы и обработки в LiederNet"]','Моряк после долгого исчезновения видит, что любимая женщина счастлива в новой семье.','Освещённое окно дома','Не воспроизводить стихотворный текст и детали музыкальной версии.'),
  ('Шёлковое пальто','thomas-hardy|the-ruined-maid','Thomas Hardy','The Ruined Maid','English','United Kingdom',1901,'https://en.wikisource.org/wiki/The_Ruined_Maid','Автор умер в 1928 году; оригинал начала XX века. Проверка для редакционного использования: public domain.','["Judith Lang Zaimont, The ruined maid"]','Две бывшие подруги встречаются; за городским блеском одной скрыта неудобная цена выбора.','Шёлковое пальто','Сохранять уважительный тон, без эксплуатации темы.'),
  ('Четырнадцать лет','rudyard-kipling|the-power-of-the-dog','Rudyard Kipling','The Power of the Dog','English','United Kingdom',1912,'https://en.wikisource.org/wiki/%22The_Power_of_the_Dog%22','Автор умер в 1936 году; оригинал до 1931 года. Проверка источника отмечает public domain в США; для редакционного использования — только независимый сюжет.','[]','Человек сознательно принимает привязанность к собаке, хотя знает о её короткой жизни.','Ожидание у двери','Не использовать строки и готовые переводы.'),
  ('Трей нырнул первым','robert-browning|tray','Robert Browning','Tray','English','United Kingdom',1870,'https://en.wikisource.org/wiki/Tray','Автор умер в 1889 году; источник отмечает public domain worldwide.','[]','Собака спасает ребёнка, а люди хотят использовать спасителя ради опытов.','Собака первой прыгает в воду','Избегать натуралистичных деталей опытов.'),
  ('Не догнать тройку','nikolay-nekrasov|troika','Николай Некрасов','Тройка','Russian','Russia',1846,'https://ru.wikisource.org/wiki/%D0%A2%D1%80%D0%BE%D0%B9%D0%BA%D0%B0_(%D0%9D%D0%B5%D0%BA%D1%80%D0%B0%D1%81%D0%BE%D0%B2)/%D0%94%D0%9E','Автор умер в 1877 году; оригинал XIX века. Проверка для редакционного использования: public domain.','[]','Девушка видит мчащуюся тройку и осознаёт навязанную ей судьбу.','Тройка, исчезающая на дороге','Сюжет обновлён без строк и финальных образов оригинала.'),
  ('Не одна на этой дороге','taras-shevchenko|kateryna','Тарас Шевченко','Катерина','Ukrainian','Ukraine',1840,'https://uk.wikisource.org/wiki/%D0%9A%D0%B0%D1%82%D0%B5%D1%80%D0%B8%D0%BD%D0%B0','Автор умер в 1861 году; оригинал XIX века. Проверка для редакционного использования: public domain.','[]','Брошенная молодая женщина сталкивается с осуждением и одиночеством.','Дорога, на которой появляется поддержка','Адаптация намеренно не повторяет саморазрушительный финал оригинала.')
) AS s(title, original_key, author_name, original_title, original_language, origin_country, original_year, source_url, rights_check, music_adaptations, source_synopsis, main_image, editor_note)
JOIN public.song_ideas i ON i.title = s.title
ON CONFLICT (idea_id) DO NOTHING;

INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'genre', trim(value) FROM public.song_ideas, unnest(genres) AS value WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;
INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'mood', trim(value) FROM public.song_ideas, unnest(moods) AS value WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;
INSERT INTO public.song_idea_taxonomy_options (kind, value)
SELECT 'theme', trim(value) FROM public.song_ideas, unnest(themes) AS value WHERE trim(value) <> ''
ON CONFLICT (kind, value) DO NOTHING;
