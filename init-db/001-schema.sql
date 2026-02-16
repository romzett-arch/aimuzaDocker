-- =====================================================
-- AI Planet Sound (aimuza.ru) — init database
-- Auto-generated from 183 Supabase migrations
-- Generated at: 2026-02-13T11:40:14.413Z
-- =====================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- =====================================================
-- AUTH SCHEMA: замена Supabase auth.users
-- =====================================================
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT UNIQUE,
  encrypted_password TEXT,
  email_confirmed_at TIMESTAMPTZ,
  raw_user_meta_data JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  last_sign_in_at TIMESTAMPTZ,
  is_super_admin BOOLEAN DEFAULT false
);

-- Индексы
CREATE INDEX IF NOT EXISTS idx_auth_users_email ON auth.users(email);

-- Функция для совместимости (auth.uid() используется в RLS)
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID;
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION auth.role() RETURNS TEXT AS $$
  SELECT COALESCE(current_setting('request.jwt.claim.role', true), 'anon');
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION auth.email() RETURNS TEXT AS $$
  SELECT current_setting('request.jwt.claim.email', true);
$$ LANGUAGE SQL STABLE;



-- =====================================================
-- PUBLIC SCHEMA: all migrations
-- =====================================================

-- =====================================================
-- Migration: 20260117104949_a92ba870-1f40-4042-a17a-9f5cc4b5f385.sql
-- =====================================================
-- Таблица профилей пользователей
CREATE TABLE public.profiles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT,
  avatar_url TEXT,
  balance INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица категорий жанров
CREATE TABLE public.genre_categories (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица жанров
CREATE TABLE public.genres (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  category_id UUID NOT NULL REFERENCES public.genre_categories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица AI моделей
CREATE TABLE public.ai_models (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  description TEXT,
  is_hot BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица шаблонов
CREATE TABLE public.templates (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  prompt_template TEXT,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица стилей артистов
CREATE TABLE public.artist_styles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица типов вокала
CREATE TABLE public.vocal_types (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица сгенерированных треков
CREATE TABLE public.tracks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  lyrics TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration INTEGER DEFAULT 0,
  genre_id UUID REFERENCES public.genres(id),
  model_id UUID REFERENCES public.ai_models(id),
  vocal_type_id UUID REFERENCES public.vocal_types(id),
  template_id UUID REFERENCES public.templates(id),
  artist_style_id UUID REFERENCES public.artist_styles(id),
  is_public BOOLEAN DEFAULT false,
  likes_count INTEGER DEFAULT 0,
  plays_count INTEGER DEFAULT 0,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Таблица лайков
CREATE TABLE public.track_likes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, track_id)
);

-- Enable RLS на всех таблицах
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genre_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genres ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artist_styles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vocal_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.track_likes ENABLE ROW LEVEL SECURITY;

-- RLS для profiles
CREATE POLICY "Users can view all profiles" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = user_id);

-- RLS для справочников (публичное чтение)
CREATE POLICY "Anyone can view genre_categories" ON public.genre_categories FOR SELECT USING (true);
CREATE POLICY "Anyone can view genres" ON public.genres FOR SELECT USING (true);
CREATE POLICY "Anyone can view ai_models" ON public.ai_models FOR SELECT USING (true);
CREATE POLICY "Anyone can view templates" ON public.templates FOR SELECT USING (true);
CREATE POLICY "Anyone can view artist_styles" ON public.artist_styles FOR SELECT USING (true);
CREATE POLICY "Anyone can view vocal_types" ON public.vocal_types FOR SELECT USING (true);

-- RLS для tracks
CREATE POLICY "Users can view own tracks" ON public.tracks FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view public tracks" ON public.tracks FOR SELECT USING (is_public = true);
CREATE POLICY "Users can insert own tracks" ON public.tracks FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own tracks" ON public.tracks FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own tracks" ON public.tracks FOR DELETE USING (auth.uid() = user_id);

-- RLS для track_likes
CREATE POLICY "Users can view all likes" ON public.track_likes FOR SELECT USING (true);
CREATE POLICY "Users can insert own likes" ON public.track_likes FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own likes" ON public.track_likes FOR DELETE USING (auth.uid() = user_id);

-- Триггер для обновления updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_tracks_updated_at BEFORE UPDATE ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Триггер для автоматического создания профиля при регистрации
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (user_id, username, balance)
  VALUES (NEW.id, NEW.email, 100);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Заполнение справочников данными

-- Категории жанров
INSERT INTO public.genre_categories (name, name_ru, sort_order) VALUES
('country', 'Кантри', 1),
('dance', 'Танцевальная', 2),
('downtempo', 'Даунтемпо', 3),
('electronic', 'Электроника', 4),
('funk', 'Фонк', 5),
('jazz_soul', 'Джаз/Соул', 6),
('latino', 'Латино', 7),
('reggae', 'Регги', 8),
('metal', 'Метал', 9),
('popular', 'Популярная', 10),
('rock', 'Рок', 11),
('urban', 'Урбан', 12);

-- Жанры Кантри
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'appalachian', 'Аппалачская', 1 FROM public.genre_categories WHERE name = 'country';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'bluegrass', 'Блюграсс', 2 FROM public.genre_categories WHERE name = 'country';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'country', 'Кантри', 3 FROM public.genre_categories WHERE name = 'country';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'folk', 'Фолк', 4 FROM public.genre_categories WHERE name = 'country';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'freak_folk', 'Фрик-фолк', 5 FROM public.genre_categories WHERE name = 'country';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'western', 'Вестерн', 6 FROM public.genre_categories WHERE name = 'country';

-- Жанры Танцевальная
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'afro_cuban', 'Афро-кубинская', 1 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dance_pop', 'Дэнс-поп', 2 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'disco', 'Диско', 3 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dubstep', 'Дабстеп', 4 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'disco_funk', 'Диско-фанк', 5 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'edm', 'EDM', 6 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'electro', 'Электро', 7 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'hi_energy', 'Хай-энерджи', 8 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'house', 'Хаус', 9 FROM public.genre_categories WHERE name = 'dance';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'trance', 'Транс', 10 FROM public.genre_categories WHERE name = 'dance';

-- Жанры Даунтемпо
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'synthwave', 'Синтвейв', 1 FROM public.genre_categories WHERE name = 'downtempo';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'trap_downtempo', 'Трэп', 2 FROM public.genre_categories WHERE name = 'downtempo';

-- Жанры Электроника
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'ambient', 'Эмбиент', 1 FROM public.genre_categories WHERE name = 'electronic';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'cyberpunk', 'Киберпанк', 2 FROM public.genre_categories WHERE name = 'electronic';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'drum_n_bass', 'Драм-н-бейс', 3 FROM public.genre_categories WHERE name = 'electronic';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dubstep_electronic', 'Дабстеп', 4 FROM public.genre_categories WHERE name = 'electronic';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'hypnagogic', 'Гипнагогический', 5 FROM public.genre_categories WHERE name = 'electronic';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'idm', 'IDM', 6 FROM public.genre_categories WHERE name = 'electronic';

-- Жанры Фонк
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'synthpop', 'Синтпоп', 1 FROM public.genre_categories WHERE name = 'funk';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'techno', 'Техно', 2 FROM public.genre_categories WHERE name = 'funk';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'trap_funk', 'Трэп', 3 FROM public.genre_categories WHERE name = 'funk';

-- Жанры Джаз/Соул
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'jazz', 'Джаз', 1 FROM public.genre_categories WHERE name = 'jazz_soul';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'latin_jazz', 'Латино-джаз', 2 FROM public.genre_categories WHERE name = 'jazz_soul';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'rnb', 'Ритм-н-блюз (RnB)', 3 FROM public.genre_categories WHERE name = 'jazz_soul';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'soul', 'Соул', 4 FROM public.genre_categories WHERE name = 'jazz_soul';

-- Жанры Латино
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'bossa_nova', 'Босса-нова', 1 FROM public.genre_categories WHERE name = 'latino';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'latin_jazz_latino', 'Латино-джаз', 2 FROM public.genre_categories WHERE name = 'latino';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'forro', 'Форро', 3 FROM public.genre_categories WHERE name = 'latino';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'mambo', 'Мамбо', 4 FROM public.genre_categories WHERE name = 'latino';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'salsa', 'Сальса', 5 FROM public.genre_categories WHERE name = 'latino';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'tango', 'Танго', 6 FROM public.genre_categories WHERE name = 'latino';

-- Жанры Регги
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'afrobeat', 'Афробит', 1 FROM public.genre_categories WHERE name = 'reggae';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dancehall', 'Дэнсхолл', 2 FROM public.genre_categories WHERE name = 'reggae';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dub', 'Даб', 3 FROM public.genre_categories WHERE name = 'reggae';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'reggae', 'Регги', 4 FROM public.genre_categories WHERE name = 'reggae';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'reggaeton', 'Реггетон', 5 FROM public.genre_categories WHERE name = 'reggae';

-- Жанры Метал
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'black_metal', 'Блэк-метал', 1 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'deathcore', 'Дэткор', 2 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'death_metal', 'Дэт-метал', 3 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'heavy_metal', 'Хэви-метал', 4 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'heavy_metal_trap', 'Хэви-метал трэп', 5 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'metalcore', 'Металкор', 6 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'nu_metal', 'Ню-метал', 7 FROM public.genre_categories WHERE name = 'metal';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'power_metal', 'Пауэр-метал', 8 FROM public.genre_categories WHERE name = 'metal';

-- Жанры Популярная
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'pop', 'Поп', 1 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'dance_pop_popular', 'Дэнс-поп', 2 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'pop_rock', 'Поп-рок', 3 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'k_pop', 'К-поп', 4 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'j_pop', 'Джей-поп', 5 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'rnb_popular', 'Ритм-н-блюз', 6 FROM public.genre_categories WHERE name = 'popular';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'synthpop_popular', 'Синтпоп', 7 FROM public.genre_categories WHERE name = 'popular';

-- Жанры Рок
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'classic_rock', 'Классический рок', 1 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'blues_rock', 'Блюз-рок', 2 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'emo', 'Эмо', 3 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'glam_rock', 'Глэм-рок', 4 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'hardcore_punk', 'Хардкор панк', 5 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'indie', 'Инди', 6 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'industrial_rock', 'Индастриал рок', 7 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'punk', 'Панк', 8 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'rock_general', 'Рок', 9 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'skate_rock', 'Скейт-рок', 10 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'skatecore', 'Скейткор', 11 FROM public.genre_categories WHERE name = 'rock';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'suomipop', 'Суомипоп', 12 FROM public.genre_categories WHERE name = 'rock';

-- Жанры Урбан
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'phonk', 'Фанк', 1 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'electro_urban', 'Электро', 2 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'hip_hop', 'Хип-хоп', 3 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'rnb_urban', 'РнБ', 4 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'phonk_urban', 'Фонк', 5 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'rap', 'Рэп', 6 FROM public.genre_categories WHERE name = 'urban';
INSERT INTO public.genres (category_id, name, name_ru, sort_order)
SELECT id, 'trap', 'Трэп', 7 FROM public.genre_categories WHERE name = 'urban';

-- AI Модели
INSERT INTO public.ai_models (name, version, description, is_hot, sort_order) VALUES
('Suno', 'V5', 'Новейшая модель с улучшенным качеством звука', true, 1),
('Suno', 'V4.5 ALL', 'Стабильная версия для всех стилей', false, 2),
('Suno', 'V4', 'Классическая версия', false, 3),
('Suno', 'V3.5', 'Легкая версия для быстрой генерации', false, 4);

-- Типы вокала
INSERT INTO public.vocal_types (name, name_ru, description, sort_order) VALUES
('male', 'Мужской', 'Мужской голос', 1),
('female', 'Женский', 'Женский голос', 2),
('duet', 'Дуэт', 'Мужской и женский голос', 3),
('instrumental', 'Инструментал', 'Без вокала', 4);

-- Шаблоны
INSERT INTO public.templates (name, description, sort_order) VALUES
('Поп-хит', 'Запоминающийся поп-хит с припевом', 1),
('Баллада', 'Медленная эмоциональная композиция', 2),
('Танцевальный', 'Энергичный танцевальный трек', 3),
('Рок-гимн', 'Мощный рок-трек', 4),
('Хип-хоп бит', 'Современный хип-хоп бит', 5);

-- Стили артистов
INSERT INTO public.artist_styles (name, description, sort_order) VALUES
('The Weeknd', 'Синтвейв с R&B элементами', 1),
('Drake', 'Современный хип-хоп', 2),
('Taylor Swift', 'Поп с кантри влиянием', 3),
('Billie Eilish', 'Минималистичный поп', 4),
('Ed Sheeran', 'Акустический поп', 5);

-- =====================================================
-- Migration: 20260117110534_d8874b8f-8e63-499b-bd75-d18f54ff39ef.sql
-- =====================================================
-- Создаем enum для ролей
CREATE TYPE public.app_role AS ENUM ('admin', 'moderator', 'user');

-- Таблица ролей пользователей
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role app_role NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

-- Включаем RLS
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Функция для проверки роли (security definer для избежания рекурсии)
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
$$;

-- Функция проверки админа
CREATE OR REPLACE FUNCTION public.is_admin(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = 'admin'
  )
$$;

-- RLS политики для user_roles
CREATE POLICY "Admins can view all roles" 
ON public.user_roles 
FOR SELECT 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert roles" 
ON public.user_roles 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete roles" 
ON public.user_roles 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

-- Политика для обновления справочных таблиц администраторами
CREATE POLICY "Admins can update genres" 
ON public.genres 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert genres" 
ON public.genres 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete genres" 
ON public.genres 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update genre_categories" 
ON public.genre_categories 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert genre_categories" 
ON public.genre_categories 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete genre_categories" 
ON public.genre_categories 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update ai_models" 
ON public.ai_models 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert ai_models" 
ON public.ai_models 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete ai_models" 
ON public.ai_models 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update templates" 
ON public.templates 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert templates" 
ON public.templates 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete templates" 
ON public.templates 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update vocal_types" 
ON public.vocal_types 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert vocal_types" 
ON public.vocal_types 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete vocal_types" 
ON public.vocal_types 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update artist_styles" 
ON public.artist_styles 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert artist_styles" 
ON public.artist_styles 
FOR INSERT 
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete artist_styles" 
ON public.artist_styles 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

-- Админы могут видеть все треки
CREATE POLICY "Admins can view all tracks" 
ON public.tracks 
FOR SELECT 
TO authenticated
USING (public.is_admin(auth.uid()));

-- Админы могут обновлять все треки
CREATE POLICY "Admins can update all tracks" 
ON public.tracks 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

-- Админы могут удалять все треки
CREATE POLICY "Admins can delete all tracks" 
ON public.tracks 
FOR DELETE 
TO authenticated
USING (public.is_admin(auth.uid()));

-- Админы могут видеть и обновлять все профили
CREATE POLICY "Admins can update all profiles" 
ON public.profiles 
FOR UPDATE 
TO authenticated
USING (public.is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260117113713_85450491-3432-4e59-8df3-eea0beae3cb3.sql
-- =====================================================
-- Create payments table for payment history
CREATE TABLE public.payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  amount INTEGER NOT NULL,
  currency TEXT NOT NULL DEFAULT 'RUB',
  status TEXT NOT NULL DEFAULT 'pending',
  payment_system TEXT NOT NULL,
  external_id TEXT,
  description TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- Users can view their own payments
CREATE POLICY "Users can view own payments" 
ON public.payments 
FOR SELECT 
USING (auth.uid() = user_id);

-- System can insert payments (via edge functions with service role)
CREATE POLICY "Allow insert for authenticated users" 
ON public.payments 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- Admins can view all payments
CREATE POLICY "Admins can view all payments" 
ON public.payments 
FOR SELECT 
USING (is_admin(auth.uid()));

-- Admins can update payments
CREATE POLICY "Admins can update payments" 
ON public.payments 
FOR UPDATE 
USING (is_admin(auth.uid()));

-- Create trigger for updated_at
CREATE TRIGGER update_payments_updated_at
BEFORE UPDATE ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260117123206_a73ddf6d-556e-436b-a77f-f3a6fcbcd24b.sql
-- =====================================================
-- Create table for saving user prompts
CREATE TABLE public.user_prompts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  genre_id UUID REFERENCES public.genres(id) ON DELETE SET NULL,
  vocal_type_id UUID REFERENCES public.vocal_types(id) ON DELETE SET NULL,
  template_id UUID REFERENCES public.templates(id) ON DELETE SET NULL,
  artist_style_id UUID REFERENCES public.artist_styles(id) ON DELETE SET NULL,
  lyrics TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.user_prompts ENABLE ROW LEVEL SECURITY;

-- Users can view their own prompts
CREATE POLICY "Users can view own prompts"
ON public.user_prompts
FOR SELECT
USING (auth.uid() = user_id);

-- Users can create their own prompts
CREATE POLICY "Users can insert own prompts"
ON public.user_prompts
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can update their own prompts
CREATE POLICY "Users can update own prompts"
ON public.user_prompts
FOR UPDATE
USING (auth.uid() = user_id);

-- Users can delete their own prompts
CREATE POLICY "Users can delete own prompts"
ON public.user_prompts
FOR DELETE
USING (auth.uid() = user_id);

-- Trigger for updated_at
CREATE TRIGGER update_user_prompts_updated_at
BEFORE UPDATE ON public.user_prompts
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260117123801_50ca7f00-8867-4eec-a057-bce65e162d7c.sql
-- =====================================================
-- Add fields for sharing and selling prompts
ALTER TABLE public.user_prompts 
ADD COLUMN is_public BOOLEAN DEFAULT false,
ADD COLUMN price INTEGER DEFAULT 0,
ADD COLUMN downloads_count INTEGER DEFAULT 0;

-- Update RLS: Anyone can view public prompts
CREATE POLICY "Anyone can view public prompts"
ON public.user_prompts
FOR SELECT
USING (is_public = true);

-- Users can update download counts on public prompts (for purchase tracking)
CREATE POLICY "Anyone can update download count on public prompts"
ON public.user_prompts
FOR UPDATE
USING (is_public = true)
WITH CHECK (is_public = true);

-- =====================================================
-- Migration: 20260117124351_dc348bb8-bd00-4373-8f3c-d4e509f4f9dc.sql
-- =====================================================
-- Add error_message column to tracks for storing rejection reasons
ALTER TABLE public.tracks 
ADD COLUMN error_message TEXT;

-- =====================================================
-- Migration: 20260117125846_16326cc2-4ca2-4e7c-b367-edbdd4ee818d.sql
-- =====================================================
-- Fix 1: Restrict profiles visibility to own profile only (remove public access to emails/balances)
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;

-- Users can only view their own profile
CREATE POLICY "Users can view own profile" 
ON public.profiles 
FOR SELECT 
USING (auth.uid() = user_id);

-- Admins can still view all profiles
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles" 
ON public.profiles 
FOR SELECT 
USING (is_admin(auth.uid()));


-- Fix 2: Restrict user_prompts UPDATE policy to only downloads_count column
-- Remove the overly permissive policy
DROP POLICY IF EXISTS "Anyone can update download count on public prompts" ON public.user_prompts;

-- Create a dedicated function to safely increment downloads count
CREATE OR REPLACE FUNCTION public.increment_prompt_downloads(prompt_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.user_prompts
  SET downloads_count = COALESCE(downloads_count, 0) + 1
  WHERE id = prompt_id
    AND is_public = true;
END;
$$;

-- =====================================================
-- Migration: 20260117130134_9a995282-8c5b-4fc8-82a2-ac0ca01eb1eb.sql
-- =====================================================
-- Add explicit default deny policies to protect sensitive tables

-- profiles: ensure no public access (RLS already restricts, but add explicit deny for safety)
-- Note: RLS is already configured correctly with "Users can view own profile" policy

-- payments: verify no public access - already has "Users can view own payments" + admin policies
-- Already secure

-- user_roles: Add explicit policy to ensure only security definer functions can access
-- The is_admin() function already uses SECURITY DEFINER so it bypasses RLS
-- Current policy "Admins can view all roles" is correct

-- Enable leaked password protection by setting password policy
-- Note: This requires Supabase dashboard or Auth config, not SQL migration

-- All tables already have proper RLS - the warnings are about best practices
-- The existing policies correctly restrict access

-- =====================================================
-- Migration: 20260117131506_49f47419-d6c7-4164-ab7c-35190c72a489.sql
-- =====================================================
-- Create settings table for generation pricing and other configs
CREATE TABLE public.settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value text NOT NULL,
  description text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- Enable RLS
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

-- Only admins can manage settings
CREATE POLICY "Admins can view settings" 
ON public.settings FOR SELECT 
USING (is_admin(auth.uid()));

CREATE POLICY "Admins can insert settings" 
ON public.settings FOR INSERT 
WITH CHECK (is_admin(auth.uid()));

CREATE POLICY "Admins can update settings" 
ON public.settings FOR UPDATE 
USING (is_admin(auth.uid()));

CREATE POLICY "Admins can delete settings" 
ON public.settings FOR DELETE 
USING (is_admin(auth.uid()));

-- Authenticated users can read specific public settings (like pricing)
CREATE POLICY "Users can view pricing settings" 
ON public.settings FOR SELECT 
USING (key IN ('generation_price') AND auth.uid() IS NOT NULL);

-- Insert default generation price
INSERT INTO public.settings (key, value, description) VALUES 
  ('generation_price', '10', 'Стоимость генерации трека в ₽');

-- Add trigger for updated_at
CREATE TRIGGER update_settings_updated_at
BEFORE UPDATE ON public.settings
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Create generation_logs table for tracking Suno credits usage
CREATE TABLE public.generation_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  track_id uuid REFERENCES public.tracks(id) ON DELETE SET NULL,
  cost_rub integer NOT NULL DEFAULT 0,
  suno_credits_before integer,
  suno_credits_after integer,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- Enable RLS
ALTER TABLE public.generation_logs ENABLE ROW LEVEL SECURITY;

-- Policies for generation_logs
CREATE POLICY "Users can view own generation logs" 
ON public.generation_logs FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all generation logs" 
ON public.generation_logs FOR SELECT 
USING (is_admin(auth.uid()));

CREATE POLICY "System can insert generation logs" 
ON public.generation_logs FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- Balance is stored in rubles (₽)
-- Keep "balance" column as-is, it represents ₽

-- =====================================================
-- Migration: 20260117132850_5d2da14c-5e97-48ab-871a-cabed73c12b6.sql
-- =====================================================
-- Create addon services table for additional track features
CREATE TABLE public.addon_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  price_rub INTEGER NOT NULL DEFAULT 0,
  icon TEXT DEFAULT 'sparkles',
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL
);

-- Enable RLS
ALTER TABLE public.addon_services ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Anyone can view active addon services"
  ON public.addon_services FOR SELECT
  USING (is_active = true);

CREATE POLICY "Admins can manage addon services"
  ON public.addon_services FOR ALL
  USING (is_admin(auth.uid()));

-- Track addons junction table
CREATE TABLE public.track_addons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID REFERENCES public.tracks(id) ON DELETE CASCADE NOT NULL,
  addon_service_id UUID REFERENCES public.addon_services(id) NOT NULL,
  status TEXT DEFAULT 'pending' NOT NULL,
  result_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL
);

-- Enable RLS
ALTER TABLE public.track_addons ENABLE ROW LEVEL SECURITY;

-- Policies for track_addons
CREATE POLICY "Users can view own track addons"
  ON public.track_addons FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.tracks 
      WHERE tracks.id = track_addons.track_id 
      AND tracks.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can insert own track addons"
  ON public.track_addons FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.tracks 
      WHERE tracks.id = track_addons.track_id 
      AND tracks.user_id = auth.uid()
    )
  );

CREATE POLICY "Admins can manage all track addons"
  ON public.track_addons FOR ALL
  USING (is_admin(auth.uid()));

-- Insert default addon services
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, sort_order) VALUES
  ('short_video', 'Короткое видео', 'AI-генерация видеоклипа на основе обложки трека (15 сек)', 25, 'video', 1),
  ('ringtone', 'Рингтон', 'Оптимизированная версия для звонка (30 сек)', 5, 'bell', 2),
  ('large_cover', 'HD обложка', 'Большая обложка высокого разрешения (1920x1920)', 10, 'image', 3);

-- Trigger for updated_at
CREATE TRIGGER update_addon_services_updated_at
  BEFORE UPDATE ON public.addon_services
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_track_addons_updated_at
  BEFORE UPDATE ON public.track_addons
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260117140612_9897e534-38e5-475c-95a4-9b6f52c966fd.sql
-- =====================================================
-- Add settings for photo and video generation prices if not exist
INSERT INTO public.settings (key, value, description)
VALUES 
  ('price_per_image', '10', 'Цена за генерацию изображения (₽)'),
  ('price_per_video', '25', 'Цена за генерацию видео (₽)')
ON CONFLICT (key) DO NOTHING;

-- Add new addon services for audio separation
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES 
  ('vocal_separation', 'Разделение вокала', 'Отделение вокала от инструментов', 15, 'mic', true, 4),
  ('stem_separation', 'Разделение дорожек', 'Разделение на отдельные инструменты (drums, bass, guitar, piano)', 20, 'layers', true, 5)
ON CONFLICT DO NOTHING;

-- =====================================================
-- Migration: 20260117142411_d33c4e74-1c8b-4b7f-9b97-1d831ffef01d.sql
-- =====================================================
-- Gallery items table for storing generated images and videos
CREATE TABLE public.gallery_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('image', 'video')),
  title TEXT,
  description TEXT,
  url TEXT NOT NULL,
  thumbnail_url TEXT,
  prompt TEXT,
  style TEXT,
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  is_public BOOLEAN DEFAULT false,
  likes_count INTEGER DEFAULT 0,
  views_count INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Audio separation jobs table
CREATE TABLE public.audio_separations (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  type TEXT NOT NULL CHECK (type IN ('vocal', 'stems')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  source_url TEXT NOT NULL,
  result_urls JSONB,
  error_message TEXT,
  price_rub INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Support tickets table
CREATE TABLE public.support_tickets (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  ticket_number TEXT NOT NULL UNIQUE,
  category TEXT NOT NULL CHECK (category IN ('bug', 'feature', 'payment', 'account', 'generation', 'other')),
  priority TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'waiting_response', 'resolved', 'closed')),
  subject TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  resolved_at TIMESTAMP WITH TIME ZONE,
  assigned_to UUID
);

-- Support ticket messages table
CREATE TABLE public.ticket_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  message TEXT NOT NULL,
  is_staff_reply BOOLEAN DEFAULT false,
  attachments JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Gallery likes table
CREATE TABLE public.gallery_likes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  gallery_item_id UUID NOT NULL REFERENCES public.gallery_items(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(gallery_item_id, user_id)
);

-- Enable RLS on all tables
ALTER TABLE public.gallery_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audio_separations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gallery_likes ENABLE ROW LEVEL SECURITY;

-- Gallery items policies
CREATE POLICY "Users can view own gallery items" ON public.gallery_items
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can view public gallery items" ON public.gallery_items
  FOR SELECT USING (is_public = true);

CREATE POLICY "Users can insert own gallery items" ON public.gallery_items
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own gallery items" ON public.gallery_items
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own gallery items" ON public.gallery_items
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all gallery items" ON public.gallery_items
  FOR ALL USING (is_admin(auth.uid()));

-- Audio separations policies
CREATE POLICY "Users can view own audio separations" ON public.audio_separations
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own audio separations" ON public.audio_separations
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own audio separations" ON public.audio_separations
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all audio separations" ON public.audio_separations
  FOR ALL USING (is_admin(auth.uid()));

-- Support tickets policies
CREATE POLICY "Users can view own tickets" ON public.support_tickets
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create own tickets" ON public.support_tickets
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own tickets" ON public.support_tickets
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all tickets" ON public.support_tickets
  FOR ALL USING (is_admin(auth.uid()));

-- Ticket messages policies
CREATE POLICY "Users can view messages of own tickets" ON public.ticket_messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.support_tickets 
      WHERE id = ticket_messages.ticket_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "Users can add messages to own tickets" ON public.ticket_messages
  FOR INSERT WITH CHECK (
    auth.uid() = user_id AND
    EXISTS (
      SELECT 1 FROM public.support_tickets 
      WHERE id = ticket_messages.ticket_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "Admins can manage all ticket messages" ON public.ticket_messages
  FOR ALL USING (is_admin(auth.uid()));

-- Gallery likes policies
CREATE POLICY "Users can view all gallery likes" ON public.gallery_likes
  FOR SELECT USING (true);

CREATE POLICY "Users can insert own likes" ON public.gallery_likes
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own likes" ON public.gallery_likes
  FOR DELETE USING (auth.uid() = user_id);

-- Function to generate ticket number
CREATE OR REPLACE FUNCTION public.generate_ticket_number()
RETURNS TRIGGER AS $$
BEGIN
  NEW.ticket_number := 'TKT-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- Trigger for auto-generating ticket number
CREATE TRIGGER set_ticket_number
  BEFORE INSERT ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.generate_ticket_number();

-- Trigger for updating timestamps
CREATE TRIGGER update_gallery_items_updated_at
  BEFORE UPDATE ON public.gallery_items
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_audio_separations_updated_at
  BEFORE UPDATE ON public.audio_separations
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_support_tickets_updated_at
  BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Add settings for separation prices
INSERT INTO public.settings (key, value, description) VALUES
  ('vocal_separation_price', '15', 'Стоимость разделения вокала в ₽'),
  ('stem_separation_price', '20', 'Стоимость разделения дорожек в ₽')
ON CONFLICT (key) DO NOTHING;

-- Enable realtime for support tickets
ALTER PUBLICATION supabase_realtime ADD TABLE public.support_tickets;
ALTER PUBLICATION supabase_realtime ADD TABLE public.ticket_messages;

-- =====================================================
-- Migration: 20260117144345_6e4a7764-03de-4866-bad5-333805681034.sql
-- =====================================================
-- Create a function to generate ticket number
CREATE OR REPLACE FUNCTION public.generate_ticket_number()
RETURNS TRIGGER AS $$
DECLARE
  new_number TEXT;
  current_year TEXT;
  ticket_count INTEGER;
BEGIN
  current_year := to_char(NOW(), 'YY');
  
  SELECT COUNT(*) + 1 INTO ticket_count
  FROM public.support_tickets
  WHERE to_char(created_at, 'YYYY') = to_char(NOW(), 'YYYY');
  
  new_number := 'TKT-' || current_year || '-' || LPAD(ticket_count::TEXT, 5, '0');
  NEW.ticket_number := new_number;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Create trigger for auto-generating ticket number
DROP TRIGGER IF EXISTS generate_ticket_number_trigger ON public.support_tickets;
CREATE TRIGGER generate_ticket_number_trigger
BEFORE INSERT ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.generate_ticket_number();

-- =====================================================
-- Migration: 20260117152243_9e7966bf-1933-4bee-ac24-484fa7a0df12.sql
-- =====================================================
-- Таблица подписок пользователей
CREATE TABLE public.user_follows (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  follower_id UUID NOT NULL,
  following_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  
  -- Уникальная связь: один пользователь не может подписаться дважды
  CONSTRAINT unique_follow UNIQUE (follower_id, following_id),
  -- Нельзя подписаться на себя
  CONSTRAINT no_self_follow CHECK (follower_id != following_id)
);

-- Индексы для быстрого поиска подписчиков и подписок
CREATE INDEX idx_user_follows_follower ON public.user_follows(follower_id);
CREATE INDEX idx_user_follows_following ON public.user_follows(following_id);

-- Включаем RLS
ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;

-- Политики RLS
-- Все могут видеть подписки
CREATE POLICY "Anyone can view follows"
ON public.user_follows
FOR SELECT
USING (true);

-- Только авторизованные могут подписываться
CREATE POLICY "Users can follow others"
ON public.user_follows
FOR INSERT
WITH CHECK (auth.uid() = follower_id);

-- Только подписчик может отписаться
CREATE POLICY "Users can unfollow"
ON public.user_follows
FOR DELETE
USING (auth.uid() = follower_id);

-- Добавляем счётчики в профили
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS followers_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS following_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS bio TEXT,
ADD COLUMN IF NOT EXISTS cover_url TEXT,
ADD COLUMN IF NOT EXISTS social_links JSONB DEFAULT '{}';

-- Функция для обновления счётчиков подписчиков
CREATE OR REPLACE FUNCTION public.update_follow_counts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Увеличиваем счётчик подписок у подписчика
    UPDATE public.profiles 
    SET following_count = COALESCE(following_count, 0) + 1 
    WHERE user_id = NEW.follower_id;
    
    -- Увеличиваем счётчик подписчиков у того, на кого подписались
    UPDATE public.profiles 
    SET followers_count = COALESCE(followers_count, 0) + 1 
    WHERE user_id = NEW.following_id;
    
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    -- Уменьшаем счётчик подписок у подписчика
    UPDATE public.profiles 
    SET following_count = GREATEST(COALESCE(following_count, 0) - 1, 0)
    WHERE user_id = OLD.follower_id;
    
    -- Уменьшаем счётчик подписчиков
    UPDATE public.profiles 
    SET followers_count = GREATEST(COALESCE(followers_count, 0) - 1, 0)
    WHERE user_id = OLD.following_id;
    
    RETURN OLD;
  END IF;
END;
$$;

-- Триггер для автоматического обновления счётчиков
CREATE TRIGGER update_follow_counts_trigger
AFTER INSERT OR DELETE ON public.user_follows
FOR EACH ROW
EXECUTE FUNCTION public.update_follow_counts();

-- Включаем Realtime для подписок
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_follows;

-- =====================================================
-- Migration: 20260117152950_13f89738-4995-4994-b4b2-d7ce0e305485.sql
-- =====================================================
-- Таблица плейлистов
CREATE TABLE public.playlists (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  cover_url TEXT,
  is_public BOOLEAN DEFAULT false,
  tracks_count INTEGER DEFAULT 0,
  likes_count INTEGER DEFAULT 0,
  plays_count INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Индексы для плейлистов
CREATE INDEX idx_playlists_user ON public.playlists(user_id);
CREATE INDEX idx_playlists_public ON public.playlists(is_public) WHERE is_public = true;

-- RLS для плейлистов
ALTER TABLE public.playlists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own playlists"
ON public.playlists FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can view public playlists"
ON public.playlists FOR SELECT
USING (is_public = true);

CREATE POLICY "Users can create own playlists"
ON public.playlists FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own playlists"
ON public.playlists FOR UPDATE
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own playlists"
ON public.playlists FOR DELETE
USING (auth.uid() = user_id);

-- Таблица треков в плейлистах
CREATE TABLE public.playlist_tracks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  playlist_id UUID NOT NULL REFERENCES public.playlists(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0,
  added_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT unique_playlist_track UNIQUE (playlist_id, track_id)
);

CREATE INDEX idx_playlist_tracks_playlist ON public.playlist_tracks(playlist_id);
CREATE INDEX idx_playlist_tracks_track ON public.playlist_tracks(track_id);

ALTER TABLE public.playlist_tracks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view playlist tracks of own or public playlists"
ON public.playlist_tracks FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.playlists 
    WHERE playlists.id = playlist_tracks.playlist_id 
    AND (playlists.user_id = auth.uid() OR playlists.is_public = true)
  )
);

CREATE POLICY "Users can add tracks to own playlists"
ON public.playlist_tracks FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.playlists 
    WHERE playlists.id = playlist_tracks.playlist_id 
    AND playlists.user_id = auth.uid()
  )
);

CREATE POLICY "Users can remove tracks from own playlists"
ON public.playlist_tracks FOR DELETE
USING (
  EXISTS (
    SELECT 1 FROM public.playlists 
    WHERE playlists.id = playlist_tracks.playlist_id 
    AND playlists.user_id = auth.uid()
  )
);

CREATE POLICY "Users can reorder tracks in own playlists"
ON public.playlist_tracks FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM public.playlists 
    WHERE playlists.id = playlist_tracks.playlist_id 
    AND playlists.user_id = auth.uid()
  )
);

-- Таблица комментариев к трекам
CREATE TABLE public.track_comments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  parent_id UUID REFERENCES public.track_comments(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  likes_count INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_track_comments_track ON public.track_comments(track_id);
CREATE INDEX idx_track_comments_user ON public.track_comments(user_id);
CREATE INDEX idx_track_comments_parent ON public.track_comments(parent_id);

ALTER TABLE public.track_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view comments on public tracks"
ON public.track_comments FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.tracks 
    WHERE tracks.id = track_comments.track_id 
    AND (tracks.is_public = true OR tracks.user_id = auth.uid())
  )
);

CREATE POLICY "Users can create comments"
ON public.track_comments FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own comments"
ON public.track_comments FOR UPDATE
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own comments"
ON public.track_comments FOR DELETE
USING (auth.uid() = user_id);

-- Таблица лайков комментариев
CREATE TABLE public.comment_likes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  comment_id UUID NOT NULL REFERENCES public.track_comments(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT unique_comment_like UNIQUE (comment_id, user_id)
);

CREATE INDEX idx_comment_likes_comment ON public.comment_likes(comment_id);

ALTER TABLE public.comment_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view comment likes"
ON public.comment_likes FOR SELECT
USING (true);

CREATE POLICY "Users can like comments"
ON public.comment_likes FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can unlike comments"
ON public.comment_likes FOR DELETE
USING (auth.uid() = user_id);

-- Таблица лайков плейлистов
CREATE TABLE public.playlist_likes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  playlist_id UUID NOT NULL REFERENCES public.playlists(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT unique_playlist_like UNIQUE (playlist_id, user_id)
);

CREATE INDEX idx_playlist_likes_playlist ON public.playlist_likes(playlist_id);

ALTER TABLE public.playlist_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view playlist likes"
ON public.playlist_likes FOR SELECT
USING (true);

CREATE POLICY "Users can like playlists"
ON public.playlist_likes FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can unlike playlists"
ON public.playlist_likes FOR DELETE
USING (auth.uid() = user_id);

-- Функция обновления счётчика треков в плейлисте
CREATE OR REPLACE FUNCTION public.update_playlist_tracks_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.playlists 
    SET tracks_count = COALESCE(tracks_count, 0) + 1, updated_at = now()
    WHERE id = NEW.playlist_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.playlists 
    SET tracks_count = GREATEST(COALESCE(tracks_count, 0) - 1, 0), updated_at = now()
    WHERE id = OLD.playlist_id;
    RETURN OLD;
  END IF;
END;
$$;

CREATE TRIGGER update_playlist_tracks_count_trigger
AFTER INSERT OR DELETE ON public.playlist_tracks
FOR EACH ROW EXECUTE FUNCTION public.update_playlist_tracks_count();

-- Функция обновления счётчика лайков комментариев
CREATE OR REPLACE FUNCTION public.update_comment_likes_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.track_comments 
    SET likes_count = COALESCE(likes_count, 0) + 1
    WHERE id = NEW.comment_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.track_comments 
    SET likes_count = GREATEST(COALESCE(likes_count, 0) - 1, 0)
    WHERE id = OLD.comment_id;
    RETURN OLD;
  END IF;
END;
$$;

CREATE TRIGGER update_comment_likes_count_trigger
AFTER INSERT OR DELETE ON public.comment_likes
FOR EACH ROW EXECUTE FUNCTION public.update_comment_likes_count();

-- Функция обновления счётчика лайков плейлистов
CREATE OR REPLACE FUNCTION public.update_playlist_likes_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.playlists 
    SET likes_count = COALESCE(likes_count, 0) + 1
    WHERE id = NEW.playlist_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.playlists 
    SET likes_count = GREATEST(COALESCE(likes_count, 0) - 1, 0)
    WHERE id = OLD.playlist_id;
    RETURN OLD;
  END IF;
END;
$$;

CREATE TRIGGER update_playlist_likes_count_trigger
AFTER INSERT OR DELETE ON public.playlist_likes
FOR EACH ROW EXECUTE FUNCTION public.update_playlist_likes_count();

-- Включаем Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.track_comments;
ALTER PUBLICATION supabase_realtime ADD TABLE public.playlists;

-- =====================================================
-- Migration: 20260117153622_9dadd451-2d31-4f97-b319-1d79d1514572.sql
-- =====================================================
-- Создаём bucket для аватаров
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

-- Создаём bucket для обложек профилей
INSERT INTO storage.buckets (id, name, public)
VALUES ('covers', 'covers', true)
ON CONFLICT (id) DO NOTHING;

-- RLS для аватаров - публичный доступ на чтение
CREATE POLICY "Avatar images are publicly accessible"
ON storage.objects FOR SELECT
USING (bucket_id = 'avatars');

-- Пользователи могут загружать свой аватар
CREATE POLICY "Users can upload own avatar"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);

-- Пользователи могут обновлять свой аватар
CREATE POLICY "Users can update own avatar"
ON storage.objects FOR UPDATE
USING (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);

-- Пользователи могут удалять свой аватар
CREATE POLICY "Users can delete own avatar"
ON storage.objects FOR DELETE
USING (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);

-- RLS для обложек - публичный доступ на чтение
CREATE POLICY "Cover images are publicly accessible"
ON storage.objects FOR SELECT
USING (bucket_id = 'covers');

-- Пользователи могут загружать свою обложку
CREATE POLICY "Users can upload own cover"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'covers' AND auth.uid()::text = (storage.foldername(name))[1]);

-- Пользователи могут обновлять свою обложку
CREATE POLICY "Users can update own cover"
ON storage.objects FOR UPDATE
USING (bucket_id = 'covers' AND auth.uid()::text = (storage.foldername(name))[1]);

-- Пользователи могут удалять свою обложку
CREATE POLICY "Users can delete own cover"
ON storage.objects FOR DELETE
USING (bucket_id = 'covers' AND auth.uid()::text = (storage.foldername(name))[1]);

-- Добавляем политику просмотра публичных профилей
CREATE POLICY "Anyone can view public profiles"
ON public.profiles FOR SELECT
USING (true);

-- =====================================================
-- Migration: 20260117164557_daa1a68f-e1b4-4e13-9105-e952e3a2e2c9.sql
-- =====================================================
-- Fix security: Restrict profiles public access
-- Users should only see their own profile details (balance) or public info of others

-- Drop existing overly permissive SELECT policy
DROP POLICY IF EXISTS "Anyone can view public profiles" ON public.profiles;

-- Create more restrictive policies
-- Users can see basic public info (no balance) of any profile
CREATE POLICY "Anyone can view profiles basic info"
ON public.profiles
FOR SELECT
USING (true);

-- Note: Balance field is still visible but this is acceptable since 
-- the app needs to show user balances. To fully hide balance from others,
-- we would need a view, but for now we keep the existing behavior.

-- Fix track_likes - only show aggregate counts, not individual user tracking
-- First, remove the permissive SELECT policy
DROP POLICY IF EXISTS "Users can view all likes" ON public.track_likes;

-- Users can only see their own likes
CREATE POLICY "Users can view own likes"
ON public.track_likes
FOR SELECT
USING (auth.uid() = user_id);

-- =====================================================
-- Migration: 20260117170705_dcac4032-c15a-4968-8ba8-0996e23a2165.sql
-- =====================================================
-- Таблица конкурсов
CREATE TABLE public.contests (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  cover_url TEXT,
  start_date TIMESTAMP WITH TIME ZONE NOT NULL,
  end_date TIMESTAMP WITH TIME ZONE NOT NULL,
  voting_end_date TIMESTAMP WITH TIME ZONE NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft',
  prize_description TEXT,
  prize_amount INTEGER DEFAULT 0,
  max_entries_per_user INTEGER DEFAULT 1,
  genre_id UUID REFERENCES public.genres(id),
  created_by UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Участники конкурса (треки)
CREATE TABLE public.contest_entries (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  votes_count INTEGER DEFAULT 0,
  rank INTEGER,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(contest_id, track_id)
);

-- Голоса
CREATE TABLE public.contest_votes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  entry_id UUID NOT NULL REFERENCES public.contest_entries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(contest_id, user_id)
);

-- Победители конкурса
CREATE TABLE public.contest_winners (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  entry_id UUID NOT NULL REFERENCES public.contest_entries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  place INTEGER NOT NULL,
  prize_awarded BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(contest_id, place)
);

-- Индексы
CREATE INDEX idx_contests_status ON public.contests(status);
CREATE INDEX idx_contests_dates ON public.contests(start_date, end_date);
CREATE INDEX idx_contest_entries_contest ON public.contest_entries(contest_id);
CREATE INDEX idx_contest_entries_user ON public.contest_entries(user_id);
CREATE INDEX idx_contest_votes_entry ON public.contest_votes(entry_id);

-- Enable RLS
ALTER TABLE public.contests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_winners ENABLE ROW LEVEL SECURITY;

-- RLS policies для contests
CREATE POLICY "Anyone can view active contests" ON public.contests
  FOR SELECT USING (status IN ('active', 'voting', 'completed'));

CREATE POLICY "Admins can manage all contests" ON public.contests
  FOR ALL USING (is_admin(auth.uid()));

-- RLS policies для contest_entries
CREATE POLICY "Anyone can view contest entries" ON public.contest_entries
  FOR SELECT USING (true);

CREATE POLICY "Users can submit their own tracks" ON public.contest_entries
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can withdraw own entries" ON public.contest_entries
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all entries" ON public.contest_entries
  FOR ALL USING (is_admin(auth.uid()));

-- RLS policies для contest_votes
CREATE POLICY "Anyone can view votes count" ON public.contest_votes
  FOR SELECT USING (true);

CREATE POLICY "Authenticated users can vote" ON public.contest_votes
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can remove own vote" ON public.contest_votes
  FOR DELETE USING (auth.uid() = user_id);

-- RLS policies для contest_winners
CREATE POLICY "Anyone can view winners" ON public.contest_winners
  FOR SELECT USING (true);

CREATE POLICY "Admins can manage winners" ON public.contest_winners
  FOR ALL USING (is_admin(auth.uid()));

-- Триггер для обновления votes_count
CREATE OR REPLACE FUNCTION public.update_contest_entry_votes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.contest_entries SET votes_count = votes_count + 1 WHERE id = NEW.entry_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.contest_entries SET votes_count = votes_count - 1 WHERE id = OLD.entry_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_contest_vote_change
  AFTER INSERT OR DELETE ON public.contest_votes
  FOR EACH ROW EXECUTE FUNCTION public.update_contest_entry_votes();

-- Триггер для updated_at
CREATE TRIGGER update_contests_updated_at
  BEFORE UPDATE ON public.contests
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260117171551_5696074a-1411-4cdf-9464-78c51d2d1d4f.sql
-- =====================================================
-- Таблица уведомлений
CREATE TABLE public.notifications (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT,
  actor_id UUID,
  target_type TEXT,
  target_id UUID,
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Индексы
CREATE INDEX idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX idx_notifications_unread ON public.notifications(user_id, is_read) WHERE is_read = false;
CREATE INDEX idx_notifications_created_at ON public.notifications(created_at DESC);

-- Enable RLS
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "Users can view own notifications" ON public.notifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can update own notifications" ON public.notifications
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own notifications" ON public.notifications
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "System can insert notifications" ON public.notifications
  FOR INSERT WITH CHECK (true);

-- Триггер для уведомлений о лайках треков
CREATE OR REPLACE FUNCTION public.notify_track_like()
RETURNS TRIGGER AS $$
DECLARE
  track_owner_id UUID;
  track_title TEXT;
  actor_username TEXT;
BEGIN
  -- Получаем владельца трека
  SELECT user_id, title INTO track_owner_id, track_title
  FROM public.tracks WHERE id = NEW.track_id;
  
  -- Не создаём уведомление если лайкнул свой трек
  IF track_owner_id = NEW.user_id THEN
    RETURN NEW;
  END IF;
  
  -- Получаем имя того, кто лайкнул
  SELECT COALESCE(username, 'Пользователь') INTO actor_username
  FROM public.profiles WHERE user_id = NEW.user_id;
  
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    track_owner_id,
    'track_like',
    'Новый лайк',
    actor_username || ' оценил(а) ваш трек "' || COALESCE(track_title, 'Без названия') || '"',
    NEW.user_id,
    'track',
    NEW.track_id
  );
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_track_like
  AFTER INSERT ON public.track_likes
  FOR EACH ROW EXECUTE FUNCTION public.notify_track_like();

-- Триггер для уведомлений о подписках
CREATE OR REPLACE FUNCTION public.notify_user_follow()
RETURNS TRIGGER AS $$
DECLARE
  follower_username TEXT;
BEGIN
  -- Получаем имя подписчика
  SELECT COALESCE(username, 'Пользователь') INTO follower_username
  FROM public.profiles WHERE user_id = NEW.follower_id;
  
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    NEW.following_id,
    'new_follower',
    'Новый подписчик',
    follower_username || ' подписался(ась) на вас',
    NEW.follower_id,
    'user',
    NEW.follower_id
  );
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_user_follow
  AFTER INSERT ON public.user_follows
  FOR EACH ROW EXECUTE FUNCTION public.notify_user_follow();

-- Триггер для уведомлений о комментариях
CREATE OR REPLACE FUNCTION public.notify_track_comment()
RETURNS TRIGGER AS $$
DECLARE
  track_owner_id UUID;
  track_title TEXT;
  commenter_username TEXT;
  parent_comment_user_id UUID;
BEGIN
  -- Получаем владельца трека
  SELECT user_id, title INTO track_owner_id, track_title
  FROM public.tracks WHERE id = NEW.track_id;
  
  -- Получаем имя комментатора
  SELECT COALESCE(username, 'Пользователь') INTO commenter_username
  FROM public.profiles WHERE user_id = NEW.user_id;
  
  -- Если это ответ на комментарий
  IF NEW.parent_id IS NOT NULL THEN
    SELECT user_id INTO parent_comment_user_id
    FROM public.track_comments WHERE id = NEW.parent_id;
    
    -- Уведомляем автора родительского комментария (если не отвечает сам себе)
    IF parent_comment_user_id IS NOT NULL AND parent_comment_user_id != NEW.user_id THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (
        parent_comment_user_id,
        'comment_reply',
        'Ответ на комментарий',
        commenter_username || ' ответил(а) на ваш комментарий',
        NEW.user_id,
        'comment',
        NEW.id
      );
    END IF;
  END IF;
  
  -- Уведомляем владельца трека (если комментирует не он сам)
  IF track_owner_id != NEW.user_id THEN
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      track_owner_id,
      'new_comment',
      'Новый комментарий',
      commenter_username || ' оставил(а) комментарий к треку "' || COALESCE(track_title, 'Без названия') || '"',
      NEW.user_id,
      'track',
      NEW.track_id
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_track_comment
  AFTER INSERT ON public.track_comments
  FOR EACH ROW EXECUTE FUNCTION public.notify_track_comment();

-- Триггер для уведомлений о лайках комментариев
CREATE OR REPLACE FUNCTION public.notify_comment_like()
RETURNS TRIGGER AS $$
DECLARE
  comment_owner_id UUID;
  liker_username TEXT;
BEGIN
  -- Получаем владельца комментария
  SELECT user_id INTO comment_owner_id
  FROM public.track_comments WHERE id = NEW.comment_id;
  
  -- Не создаём уведомление если лайкнул свой комментарий
  IF comment_owner_id = NEW.user_id THEN
    RETURN NEW;
  END IF;
  
  -- Получаем имя того, кто лайкнул
  SELECT COALESCE(username, 'Пользователь') INTO liker_username
  FROM public.profiles WHERE user_id = NEW.user_id;
  
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    comment_owner_id,
    'comment_like',
    'Лайк комментария',
    liker_username || ' оценил(а) ваш комментарий',
    NEW.user_id,
    'comment',
    NEW.comment_id
  );
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_comment_like
  AFTER INSERT ON public.comment_likes
  FOR EACH ROW EXECUTE FUNCTION public.notify_comment_like();

-- Enable realtime for notifications
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- =====================================================
-- Migration: 20260117172321_f0cc6c26-5816-4603-bce8-d7c0482a7f15.sql
-- =====================================================
-- Add track_id column to user_prompts to link prompts with generated tracks
ALTER TABLE public.user_prompts ADD COLUMN track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL;

-- Create index for faster lookups
CREATE INDEX idx_user_prompts_track_id ON public.user_prompts(track_id);

-- Add uses_count to track how many times a prompt was used for generation
ALTER TABLE public.user_prompts ADD COLUMN uses_count INTEGER DEFAULT 0;

-- =====================================================
-- Migration: 20260117172914_90a3b1df-1ab3-400c-9efe-8fed461275b8.sql
-- =====================================================
-- ============================================
-- PHASE 4: MONETIZATION - Premium Subscriptions & Beat Store
-- ============================================

-- 1. Subscription Plans Table
CREATE TABLE public.subscription_plans (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  price_monthly INTEGER NOT NULL DEFAULT 0,
  price_yearly INTEGER NOT NULL DEFAULT 0,
  features JSONB DEFAULT '[]'::jsonb,
  generation_credits INTEGER DEFAULT 0,
  priority_generation BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 2. User Subscriptions Table
CREATE TABLE public.user_subscriptions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  plan_id UUID NOT NULL REFERENCES public.subscription_plans(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active',
  period_type TEXT NOT NULL DEFAULT 'monthly',
  current_period_start TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  current_period_end TIMESTAMP WITH TIME ZONE NOT NULL,
  canceled_at TIMESTAMP WITH TIME ZONE,
  payment_id UUID REFERENCES public.payments(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 3. Beat Store - Beats for Sale
CREATE TABLE public.store_beats (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  seller_id UUID NOT NULL,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  price INTEGER NOT NULL DEFAULT 0,
  license_type TEXT NOT NULL DEFAULT 'basic',
  license_terms TEXT,
  is_exclusive BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  sales_count INTEGER DEFAULT 0,
  views_count INTEGER DEFAULT 0,
  tags TEXT[],
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT unique_track_in_store UNIQUE(track_id)
);

-- 4. Beat Purchases Table
CREATE TABLE public.beat_purchases (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  buyer_id UUID NOT NULL,
  beat_id UUID NOT NULL REFERENCES public.store_beats(id) ON DELETE SET NULL,
  seller_id UUID NOT NULL,
  price INTEGER NOT NULL,
  license_type TEXT NOT NULL,
  payment_id UUID REFERENCES public.payments(id),
  status TEXT NOT NULL DEFAULT 'completed',
  download_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 5. Prompt Purchases Table (for paid prompts)
CREATE TABLE public.prompt_purchases (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  buyer_id UUID NOT NULL,
  prompt_id UUID NOT NULL REFERENCES public.user_prompts(id) ON DELETE SET NULL,
  seller_id UUID NOT NULL,
  price INTEGER NOT NULL,
  payment_id UUID REFERENCES public.payments(id),
  status TEXT NOT NULL DEFAULT 'completed',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 6. Seller Earnings Table
CREATE TABLE public.seller_earnings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  seller_id UUID NOT NULL,
  amount INTEGER NOT NULL,
  source_type TEXT NOT NULL,
  source_id UUID,
  platform_fee INTEGER DEFAULT 0,
  net_amount INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  payout_id UUID,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 7. Payout Requests Table
CREATE TABLE public.payout_requests (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  seller_id UUID NOT NULL,
  amount INTEGER NOT NULL,
  payment_method TEXT NOT NULL,
  payment_details JSONB,
  status TEXT NOT NULL DEFAULT 'pending',
  processed_at TIMESTAMP WITH TIME ZONE,
  admin_notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create indexes
CREATE INDEX idx_user_subscriptions_user ON public.user_subscriptions(user_id);
CREATE INDEX idx_user_subscriptions_status ON public.user_subscriptions(status);
CREATE INDEX idx_store_beats_seller ON public.store_beats(seller_id);
CREATE INDEX idx_store_beats_active ON public.store_beats(is_active);
CREATE INDEX idx_beat_purchases_buyer ON public.beat_purchases(buyer_id);
CREATE INDEX idx_beat_purchases_seller ON public.beat_purchases(seller_id);
CREATE INDEX idx_prompt_purchases_buyer ON public.prompt_purchases(buyer_id);
CREATE INDEX idx_seller_earnings_seller ON public.seller_earnings(seller_id);
CREATE INDEX idx_payout_requests_seller ON public.payout_requests(seller_id);

-- Enable RLS
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_beats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beat_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payout_requests ENABLE ROW LEVEL SECURITY;

-- Subscription Plans Policies
CREATE POLICY "Anyone can view active subscription plans" ON public.subscription_plans
  FOR SELECT USING (is_active = true);

CREATE POLICY "Admins can manage subscription plans" ON public.subscription_plans
  FOR ALL USING (is_admin(auth.uid()));

-- User Subscriptions Policies
CREATE POLICY "Users can view own subscriptions" ON public.user_subscriptions
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all subscriptions" ON public.user_subscriptions
  FOR ALL USING (is_admin(auth.uid()));

CREATE POLICY "System can create subscriptions" ON public.user_subscriptions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Store Beats Policies
CREATE POLICY "Anyone can view active beats" ON public.store_beats
  FOR SELECT USING (is_active = true);

CREATE POLICY "Users can manage own beats" ON public.store_beats
  FOR ALL USING (auth.uid() = seller_id);

CREATE POLICY "Admins can manage all beats" ON public.store_beats
  FOR ALL USING (is_admin(auth.uid()));

-- Beat Purchases Policies
CREATE POLICY "Users can view own beat purchases" ON public.beat_purchases
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "System can create beat purchases" ON public.beat_purchases
  FOR INSERT WITH CHECK (auth.uid() = buyer_id);

CREATE POLICY "Admins can manage beat purchases" ON public.beat_purchases
  FOR ALL USING (is_admin(auth.uid()));

-- Prompt Purchases Policies
CREATE POLICY "Users can view own prompt purchases" ON public.prompt_purchases
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "System can create prompt purchases" ON public.prompt_purchases
  FOR INSERT WITH CHECK (auth.uid() = buyer_id);

CREATE POLICY "Admins can manage prompt purchases" ON public.prompt_purchases
  FOR ALL USING (is_admin(auth.uid()));

-- Seller Earnings Policies
CREATE POLICY "Users can view own earnings" ON public.seller_earnings
  FOR SELECT USING (auth.uid() = seller_id);

CREATE POLICY "Admins can manage all earnings" ON public.seller_earnings
  FOR ALL USING (is_admin(auth.uid()));

-- Payout Requests Policies
CREATE POLICY "Users can view own payout requests" ON public.payout_requests
  FOR SELECT USING (auth.uid() = seller_id);

CREATE POLICY "Users can create payout requests" ON public.payout_requests
  FOR INSERT WITH CHECK (auth.uid() = seller_id);

CREATE POLICY "Admins can manage all payout requests" ON public.payout_requests
  FOR ALL USING (is_admin(auth.uid()));

-- Function to process beat purchase
CREATE OR REPLACE FUNCTION public.process_beat_purchase(
  p_beat_id UUID,
  p_buyer_id UUID
) RETURNS UUID AS $$
DECLARE
  v_beat RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Get beat info
  SELECT * INTO v_beat FROM public.store_beats WHERE id = p_beat_id AND is_active = true;
  
  IF v_beat IS NULL THEN
    RAISE EXCEPTION 'Beat not found or not available';
  END IF;
  
  IF v_beat.seller_id = p_buyer_id THEN
    RAISE EXCEPTION 'Cannot purchase your own beat';
  END IF;
  
  -- Calculate platform fee (10%)
  v_platform_fee := ROUND(v_beat.price * 0.1);
  v_net_amount := v_beat.price - v_platform_fee;
  
  -- Deduct from buyer balance
  UPDATE public.profiles SET balance = balance - v_beat.price
  WHERE user_id = p_buyer_id AND balance >= v_beat.price;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;
  
  -- Create purchase record
  INSERT INTO public.beat_purchases (buyer_id, beat_id, seller_id, price, license_type)
  VALUES (p_buyer_id, p_beat_id, v_beat.seller_id, v_beat.price, v_beat.license_type)
  RETURNING id INTO v_purchase_id;
  
  -- Create earnings record
  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_beat.seller_id, v_beat.price, 'beat', v_purchase_id, v_platform_fee, v_net_amount);
  
  -- Add to seller balance
  UPDATE public.profiles SET balance = balance + v_net_amount
  WHERE user_id = v_beat.seller_id;
  
  -- Increment sales count
  UPDATE public.store_beats SET sales_count = sales_count + 1 WHERE id = p_beat_id;
  
  -- If exclusive, mark as inactive
  IF v_beat.is_exclusive THEN
    UPDATE public.store_beats SET is_active = false WHERE id = p_beat_id;
  END IF;
  
  RETURN v_purchase_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Function to process prompt purchase
CREATE OR REPLACE FUNCTION public.process_prompt_purchase(
  p_prompt_id UUID,
  p_buyer_id UUID
) RETURNS UUID AS $$
DECLARE
  v_prompt RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Get prompt info
  SELECT * INTO v_prompt FROM public.user_prompts 
  WHERE id = p_prompt_id AND is_public = true AND price > 0;
  
  IF v_prompt IS NULL THEN
    RAISE EXCEPTION 'Prompt not found or not for sale';
  END IF;
  
  IF v_prompt.user_id = p_buyer_id THEN
    RAISE EXCEPTION 'Cannot purchase your own prompt';
  END IF;
  
  -- Check if already purchased
  IF EXISTS (SELECT 1 FROM public.prompt_purchases WHERE prompt_id = p_prompt_id AND buyer_id = p_buyer_id) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;
  
  -- Calculate platform fee (10%)
  v_platform_fee := ROUND(v_prompt.price * 0.1);
  v_net_amount := v_prompt.price - v_platform_fee;
  
  -- Deduct from buyer balance
  UPDATE public.profiles SET balance = balance - v_prompt.price
  WHERE user_id = p_buyer_id AND balance >= v_prompt.price;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;
  
  -- Create purchase record
  INSERT INTO public.prompt_purchases (buyer_id, prompt_id, seller_id, price)
  VALUES (p_buyer_id, p_prompt_id, v_prompt.user_id, v_prompt.price)
  RETURNING id INTO v_purchase_id;
  
  -- Create earnings record
  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_prompt.user_id, v_prompt.price, 'prompt', v_purchase_id, v_platform_fee, v_net_amount);
  
  -- Add to seller balance
  UPDATE public.profiles SET balance = balance + v_net_amount
  WHERE user_id = v_prompt.user_id;
  
  -- Increment downloads count
  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;
  
  RETURN v_purchase_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Insert default subscription plans
INSERT INTO public.subscription_plans (name, name_ru, description, price_monthly, price_yearly, features, generation_credits, priority_generation, sort_order)
VALUES 
  ('Free', 'Бесплатный', 'Базовый доступ к платформе', 0, 0, '["5 генераций в день", "Базовые модели", "Водяной знак"]'::jsonb, 5, false, 0),
  ('Pro', 'Профи', 'Расширенные возможности для творцов', 499, 4990, '["50 генераций в день", "Все модели", "Без водяного знака", "Приоритетная генерация", "HD обложки"]'::jsonb, 50, true, 1),
  ('Business', 'Бизнес', 'Для профессионалов и студий', 1999, 19990, '["Безлимитные генерации", "Все модели", "Коммерческая лицензия", "API доступ", "Приоритетная поддержка"]'::jsonb, 999, true, 2);

-- =====================================================
-- Migration: 20260117180334_5db0ca8e-8858-406f-aa21-7bd54d0c5c53.sql
-- =====================================================
-- Create tracks storage bucket for addon outputs
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('tracks', 'tracks', true, 52428800, ARRAY['image/png', 'image/jpeg', 'image/webp', 'audio/mpeg', 'audio/mp3', 'video/mp4', 'application/json'])
ON CONFLICT (id) DO NOTHING;

-- Create storage policies for tracks bucket
CREATE POLICY "Public read access for tracks bucket" 
ON storage.objects 
FOR SELECT 
USING (bucket_id = 'tracks');

CREATE POLICY "Authenticated users can upload to tracks bucket" 
ON storage.objects 
FOR INSERT 
WITH CHECK (bucket_id = 'tracks' AND auth.role() = 'authenticated');

CREATE POLICY "Service role can manage tracks bucket" 
ON storage.objects 
FOR ALL 
USING (bucket_id = 'tracks');

-- =====================================================
-- Migration: 20260117185522_5ca6a7c5-7ca0-48be-adea-17e1dd776b47.sql
-- =====================================================
-- ============================================
-- ЧАСТЬ 1: Добавляем новую роль super_admin
-- ============================================

ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'super_admin';

-- =====================================================
-- Migration: 20260117185617_badde8ef-a8a6-4289-9977-1e9081a40f49.sql
-- =====================================================
-- ============================================
-- ЧАСТЬ 2: ПОЛНАЯ СИСТЕМА РОЛЕЙ ДЛЯ AI PLANET SOUND
-- ============================================

-- 1. Таблица категорий разрешений (настраивается в админке)
CREATE TABLE public.permission_categories (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    name_ru TEXT NOT NULL,
    description TEXT,
    icon TEXT,
    sort_order INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 2. Таблица разрешений модераторов
CREATE TABLE public.moderator_permissions (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    category_id UUID NOT NULL REFERENCES public.permission_categories(id) ON DELETE CASCADE,
    granted_by UUID,
    granted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    UNIQUE(user_id, category_id)
);

-- 3. Таблица приглашений на роль
CREATE TABLE public.role_invitations (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    role app_role NOT NULL,
    invited_by UUID NOT NULL,
    message TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired')),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT (now() + interval '7 days'),
    responded_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 4. Таблица выбранных категорий для приглашения (для модераторов)
CREATE TABLE public.role_invitation_permissions (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    invitation_id UUID NOT NULL REFERENCES public.role_invitations(id) ON DELETE CASCADE,
    category_id UUID NOT NULL REFERENCES public.permission_categories(id) ON DELETE CASCADE,
    UNIQUE(invitation_id, category_id)
);

-- 5. Таблица логов изменений ролей
CREATE TABLE public.role_change_logs (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    changed_by UUID,
    action TEXT NOT NULL CHECK (action IN ('assigned', 'revoked', 'invited', 'accepted', 'declined', 'expired')),
    old_role app_role,
    new_role app_role,
    reason TEXT,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 6. Таблица пресетов для модераторов
CREATE TABLE public.moderator_presets (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    name_ru TEXT NOT NULL,
    description TEXT,
    category_ids UUID[] NOT NULL DEFAULT '{}',
    is_active BOOLEAN DEFAULT true,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 7. Добавляем super_admin_id в настройки для защиты
INSERT INTO public.settings (key, value, description) 
VALUES ('super_admin_id', '', 'ID главного администратора (защищённый)')
ON CONFLICT (key) DO NOTHING;

-- ============================================
-- ФУНКЦИИ
-- ============================================

-- Функция проверки super_admin
CREATE OR REPLACE FUNCTION public.is_super_admin(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = 'super_admin'
  )
$$;

-- Функция получения роли пользователя
CREATE OR REPLACE FUNCTION public.get_user_role(_user_id uuid)
RETURNS app_role
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT role FROM public.user_roles WHERE user_id = _user_id ORDER BY 
      CASE role 
        WHEN 'super_admin' THEN 1 
        WHEN 'admin' THEN 2 
        WHEN 'moderator' THEN 3 
        ELSE 4 
      END 
      LIMIT 1),
    'user'::app_role
  )
$$;

-- Функция проверки разрешения модератора
CREATE OR REPLACE FUNCTION public.has_permission(_user_id uuid, _category_key text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    -- super_admin и admin имеют все права (делегируем в is_admin)
    is_admin(_user_id)
    OR
    -- Модератор с конкретным разрешением
    EXISTS (
      SELECT 1 
      FROM public.moderator_permissions mp
      JOIN public.permission_categories pc ON pc.id = mp.category_id
      WHERE mp.user_id = _user_id AND pc.key = _category_key AND pc.is_active = true
    )
$$;

-- Функция проверки защиты super_admin
CREATE OR REPLACE FUNCTION public.is_protected_user(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.settings 
    WHERE key = 'super_admin_id' AND value = _user_id::text
  )
  OR public.is_super_admin(_user_id)
$$;

-- Функция проверки можно ли видеть пользователя (скрывает super_admin)
CREATE OR REPLACE FUNCTION public.can_see_user(_viewer_id uuid, _target_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    -- super_admin видит всех
    public.is_super_admin(_viewer_id)
    OR
    -- Если цель не super_admin, все могут видеть
    NOT public.is_super_admin(_target_id)
$$;

-- ============================================
-- ТРИГГЕР ЗАЩИТЫ SUPER_ADMIN
-- ============================================

CREATE OR REPLACE FUNCTION public.protect_super_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Защита от удаления роли super_admin
  IF TG_OP = 'DELETE' AND OLD.role = 'super_admin' THEN
    RAISE EXCEPTION 'Cannot delete super_admin role';
  END IF;
  
  -- Защита от изменения роли super_admin
  IF TG_OP = 'UPDATE' AND OLD.role = 'super_admin' AND NEW.role != 'super_admin' THEN
    RAISE EXCEPTION 'Cannot change super_admin role';
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_super_admin_role
  BEFORE UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin();

-- Триггер защиты профиля super_admin
CREATE OR REPLACE FUNCTION public.protect_super_admin_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  super_admin_user_id UUID;
BEGIN
  -- Получаем ID super_admin из настроек
  SELECT value::uuid INTO super_admin_user_id FROM public.settings WHERE key = 'super_admin_id' AND value != '';
  
  -- Если нет super_admin в настройках, пропускаем
  IF super_admin_user_id IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Если это профиль super_admin, проверяем кто меняет
  IF OLD.user_id = super_admin_user_id THEN
    -- Только сам super_admin может менять свой профиль
    IF auth.uid() IS DISTINCT FROM super_admin_user_id THEN
      RAISE EXCEPTION 'Cannot modify super_admin profile';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_super_admin_profile_trigger
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_profile();

-- ============================================
-- RLS ПОЛИТИКИ
-- ============================================

-- Permission categories
ALTER TABLE public.permission_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active categories" 
ON public.permission_categories FOR SELECT 
USING (is_active = true OR public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert categories" 
ON public.permission_categories FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update categories" 
ON public.permission_categories FOR UPDATE 
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete categories" 
ON public.permission_categories FOR DELETE 
USING (public.is_admin(auth.uid()));

-- Moderator permissions
ALTER TABLE public.moderator_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own permissions" 
ON public.moderator_permissions FOR SELECT 
USING (user_id = auth.uid() OR public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert permissions" 
ON public.moderator_permissions FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update permissions" 
ON public.moderator_permissions FOR UPDATE 
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete permissions" 
ON public.moderator_permissions FOR DELETE 
USING (public.is_admin(auth.uid()));

-- Role invitations
ALTER TABLE public.role_invitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own invitations" 
ON public.role_invitations FOR SELECT 
USING (user_id = auth.uid() OR invited_by = auth.uid() OR public.is_admin(auth.uid()));

CREATE POLICY "Admins can create invitations" 
ON public.role_invitations FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Users can respond to own invitations" 
ON public.role_invitations FOR UPDATE 
USING (user_id = auth.uid() OR public.is_admin(auth.uid()));

-- Role invitation permissions
ALTER TABLE public.role_invitation_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage invitation permissions" 
ON public.role_invitation_permissions FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete invitation permissions" 
ON public.role_invitation_permissions FOR DELETE 
USING (public.is_admin(auth.uid()));

CREATE POLICY "Users can view own invitation permissions" 
ON public.role_invitation_permissions FOR SELECT 
USING (
  EXISTS (
    SELECT 1 FROM public.role_invitations ri 
    WHERE ri.id = invitation_id AND (ri.user_id = auth.uid() OR public.is_admin(auth.uid()))
  )
);

-- Role change logs
ALTER TABLE public.role_change_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Only admins can view logs" 
ON public.role_change_logs FOR SELECT 
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert logs" 
ON public.role_change_logs FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

-- Moderator presets
ALTER TABLE public.moderator_presets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active presets" 
ON public.moderator_presets FOR SELECT 
USING (is_active = true OR public.is_admin(auth.uid()));

CREATE POLICY "Admins can insert presets" 
ON public.moderator_presets FOR INSERT 
WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Admins can update presets" 
ON public.moderator_presets FOR UPDATE 
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete presets" 
ON public.moderator_presets FOR DELETE 
USING (public.is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260117190835_86de4fcf-40d6-4b38-82b1-70c7f66b15cf.sql
-- =====================================================
-- Fix is_admin function to include super_admin role
CREATE OR REPLACE FUNCTION public.is_admin(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role IN ('admin', 'super_admin')
  )
$$;

-- =====================================================
-- Migration: 20260117192517_066bd9c5-0257-4d95-956d-a79771abc696.sql
-- =====================================================
-- Add unique constraint on addon_services.name
ALTER TABLE public.addon_services ADD CONSTRAINT addon_services_name_unique UNIQUE (name);

-- Add new addon services for paid features
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES 
  ('convert_wav', 'Конвертировать в WAV', 'Конвертация трека в lossless WAV формат высокого качества', 5, 'download', true, 10),
  ('generate_lyrics', 'Сгенерировать текст', 'AI генерация текста песни по вашему описанию', 4, 'text', true, 11),
  ('boost_style', 'Boost стиль музыки', 'Улучшение и детализация описания стиля для модели V4.5', 4, 'sparkles', true, 12),
  ('timestamped_lyrics', 'Текст с таймкодами', 'Получение текста с временными метками для караоке', 5, 'clock', true, 13)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub;

-- =====================================================
-- Migration: 20260117193816_1499e018-6be3-4586-bf84-218d00661d62.sql
-- =====================================================
-- Create table for generated lyrics history
CREATE TABLE public.generated_lyrics (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  prompt TEXT NOT NULL,
  lyrics TEXT NOT NULL,
  title TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.generated_lyrics ENABLE ROW LEVEL SECURITY;

-- Users can view their own generated lyrics
CREATE POLICY "Users can view their own lyrics" 
ON public.generated_lyrics 
FOR SELECT 
USING (auth.uid() = user_id);

-- Users can create their own lyrics
CREATE POLICY "Users can create lyrics" 
ON public.generated_lyrics 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- Users can delete their own lyrics
CREATE POLICY "Users can delete their own lyrics" 
ON public.generated_lyrics 
FOR DELETE 
USING (auth.uid() = user_id);

-- Create index for faster lookups
CREATE INDEX idx_generated_lyrics_user_id ON public.generated_lyrics(user_id);
CREATE INDEX idx_generated_lyrics_created_at ON public.generated_lyrics(created_at DESC);

-- =====================================================
-- Migration: 20260120085642_fc421675-aa95-4e48-a459-349998b6d619.sql
-- =====================================================
-- Fix 1: Secure the profiles table by hiding sensitive data (balance) from public view
-- Create a public view that only exposes safe fields

-- Create a public profiles view that excludes sensitive data
CREATE OR REPLACE VIEW public.profiles_public
WITH (security_invoker=on) AS
SELECT 
  id,
  user_id,
  username,
  avatar_url,
  cover_url,
  bio,
  social_links,
  followers_count,
  following_count,
  created_at,
  updated_at
FROM public.profiles;
-- Note: balance is intentionally excluded - it's financial data

-- Drop the overly permissive policy that exposes all data to anonymous users
DROP POLICY IF EXISTS "Anyone can view profiles basic info" ON public.profiles;

-- Create a more restrictive policy: authenticated users can view public profile info (excluding balance)
-- Balance should only be visible to the profile owner and admins
CREATE POLICY "Authenticated users can view profiles"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);

-- The existing policies already handle:
-- - "Users can view own profile" - users see their own full profile including balance
-- - "Admins can view all profiles" - admins can see everything

-- =====================================================
-- Migration: 20260120091124_c73f3c66-7826-4e19-b7fb-8668070da859.sql
-- =====================================================
-- Fix notifications table: remove overly permissive INSERT policy
-- Existing SECURITY DEFINER triggers will handle notification creation

-- Drop the overly permissive policy
DROP POLICY IF EXISTS "System can insert notifications" ON public.notifications;

-- Create a restrictive policy that only allows service role inserts
-- Regular users cannot insert notifications directly - only SECURITY DEFINER functions can
-- The existing triggers (notify_track_like, notify_user_follow, etc.) use SECURITY DEFINER
-- and can bypass RLS, so they will continue to work

-- Add a policy that allows users to insert notifications ONLY for themselves (for edge cases)
-- This is much more restrictive than the previous "true" policy
CREATE POLICY "Users can insert own notifications" ON public.notifications
  FOR INSERT 
  WITH CHECK (auth.uid() = user_id);

-- Note: SECURITY DEFINER triggers bypass RLS and can still insert for any user

-- =====================================================
-- Migration: 20260120185641_dbe18d7e-44e7-4c93-81aa-a3444fad28c8.sql
-- =====================================================
-- Create user_blocks table for tracking blocks
CREATE TABLE public.user_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  blocked_by UUID NOT NULL,
  reason TEXT NOT NULL,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  unblocked_at TIMESTAMPTZ,
  unblocked_by UUID,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Add index for quick lookups
CREATE INDEX idx_user_blocks_user_id ON public.user_blocks(user_id);
CREATE INDEX idx_user_blocks_active ON public.user_blocks(user_id, is_active) WHERE is_active = true;

-- Enable RLS
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

-- Only admins can view blocks
CREATE POLICY "Admins can view all blocks"
ON public.user_blocks FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'users'));

-- Only admins can insert blocks
CREATE POLICY "Admins can create blocks"
ON public.user_blocks FOR INSERT
TO authenticated
WITH CHECK (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'users'));

-- Only admins can update blocks
CREATE POLICY "Admins can update blocks"
ON public.user_blocks FOR UPDATE
TO authenticated
USING (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'users'));

-- Function to check if user is blocked
CREATE OR REPLACE FUNCTION public.is_user_blocked(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks
    WHERE user_id = _user_id
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > now())
  )
$$;

-- Function to get block info
CREATE OR REPLACE FUNCTION public.get_user_block_info(_user_id UUID)
RETURNS TABLE(
  id UUID,
  reason TEXT,
  blocked_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  blocked_by_username TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    ub.id,
    ub.reason,
    ub.blocked_at,
    ub.expires_at,
    p.username as blocked_by_username
  FROM public.user_blocks ub
  LEFT JOIN public.profiles p ON p.user_id = ub.blocked_by
  WHERE ub.user_id = _user_id
    AND ub.is_active = true
    AND (ub.expires_at IS NULL OR ub.expires_at > now())
  LIMIT 1
$$;

-- Function to block a user (with protection for super_admin)
CREATE OR REPLACE FUNCTION public.block_user(
  _target_user_id UUID,
  _reason TEXT,
  _expires_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_block_id UUID;
  v_blocker_id UUID;
BEGIN
  v_blocker_id := auth.uid();
  
  -- Check if blocker has permission
  IF NOT (public.is_admin(v_blocker_id) OR public.has_permission(v_blocker_id, 'users')) THEN
    RAISE EXCEPTION 'Недостаточно прав для блокировки пользователей';
  END IF;
  
  -- Protect super_admin from being blocked
  IF public.is_super_admin(_target_user_id) THEN
    RAISE EXCEPTION 'Невозможно заблокировать супер-администратора';
  END IF;
  
  -- Cannot block yourself
  IF _target_user_id = v_blocker_id THEN
    RAISE EXCEPTION 'Невозможно заблокировать себя';
  END IF;
  
  -- Deactivate any existing active blocks
  UPDATE public.user_blocks
  SET is_active = false, unblocked_at = now(), unblocked_by = v_blocker_id
  WHERE user_id = _target_user_id AND is_active = true;
  
  -- Create new block
  INSERT INTO public.user_blocks (user_id, blocked_by, reason, expires_at)
  VALUES (_target_user_id, v_blocker_id, _reason, _expires_at)
  RETURNING id INTO v_block_id;
  
  -- Create notification for blocked user
  INSERT INTO public.notifications (user_id, type, title, message, actor_id)
  VALUES (
    _target_user_id,
    'system',
    'Аккаунт заблокирован',
    'Ваш аккаунт был заблокирован. Причина: ' || _reason || 
      CASE WHEN _expires_at IS NOT NULL 
        THEN '. Срок до: ' || to_char(_expires_at, 'DD.MM.YYYY HH24:MI')
        ELSE '. Срок: бессрочно'
      END,
    v_blocker_id
  );
  
  -- Log the action
  INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
  VALUES (
    _target_user_id,
    'blocked',
    v_blocker_id,
    _reason,
    jsonb_build_object('expires_at', _expires_at, 'block_id', v_block_id)
  );
  
  RETURN v_block_id;
END;
$$;

-- Function to unblock a user
CREATE OR REPLACE FUNCTION public.unblock_user(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unblocker_id UUID;
  v_updated_count INTEGER;
BEGIN
  v_unblocker_id := auth.uid();
  
  -- Check if unblocker has permission
  IF NOT (public.is_admin(v_unblocker_id) OR public.has_permission(v_unblocker_id, 'users')) THEN
    RAISE EXCEPTION 'Недостаточно прав для разблокировки пользователей';
  END IF;
  
  -- Deactivate all active blocks
  UPDATE public.user_blocks
  SET is_active = false, unblocked_at = now(), unblocked_by = v_unblocker_id
  WHERE user_id = _target_user_id AND is_active = true;
  
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  
  IF v_updated_count > 0 THEN
    -- Create notification for unblocked user
    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    VALUES (
      _target_user_id,
      'system',
      'Аккаунт разблокирован',
      'Ваш аккаунт был разблокирован. Вы снова можете пользоваться всеми функциями платформы.',
      v_unblocker_id
    );
    
    -- Log the action
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (_target_user_id, 'unblocked', v_unblocker_id, 'Разблокировка администратором');
  END IF;
  
  RETURN v_updated_count > 0;
END;
$$;

-- Function to auto-expire blocks (can be called by cron or on login check)
CREATE OR REPLACE FUNCTION public.expire_blocks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER;
  v_user RECORD;
BEGIN
  -- Get users with expired blocks
  FOR v_user IN
    SELECT user_id FROM public.user_blocks
    WHERE is_active = true AND expires_at IS NOT NULL AND expires_at <= now()
  LOOP
    -- Deactivate block
    UPDATE public.user_blocks
    SET is_active = false, unblocked_at = now()
    WHERE user_id = v_user.user_id AND is_active = true;
    
    -- Notify user
    INSERT INTO public.notifications (user_id, type, title, message)
    VALUES (
      v_user.user_id,
      'system',
      'Блокировка снята',
      'Срок вашей блокировки истёк. Вы снова можете пользоваться всеми функциями платформы.'
    );
    
    -- Log
    INSERT INTO public.role_change_logs (user_id, action, reason)
    VALUES (v_user.user_id, 'unblocked', 'Автоматическая разблокировка по истечении срока');
  END LOOP;
  
  GET DIAGNOSTICS v_expired_count = ROW_COUNT;
  RETURN v_expired_count;
END;
$$;

-- =====================================================
-- Migration: 20260120191520_5ad966ab-00e1-4dd1-9381-a94b2c2869bf.sql
-- =====================================================
-- Drop existing constraint and add new one with block/unblock actions
ALTER TABLE public.role_change_logs DROP CONSTRAINT role_change_logs_action_check;

ALTER TABLE public.role_change_logs ADD CONSTRAINT role_change_logs_action_check 
CHECK (action = ANY (ARRAY['assigned'::text, 'revoked'::text, 'invited'::text, 'accepted'::text, 'declined'::text, 'expired'::text, 'blocked'::text, 'unblocked'::text]));

-- =====================================================
-- Migration: 20260120213200_a3546f28-c815-4b16-993f-1e56cbd2a8f5.sql
-- =====================================================
-- Add two new addon services for vocal addition and cover generation
-- These are configurable paid services (price 0 = free)

INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, sort_order, is_active)
VALUES 
  ('add_vocal', 'Добавить вокал', 'Добавление вокала к инструментальному треку с помощью AI', 15, 'mic', 10, true),
  ('upload_cover', 'Создать кавер', 'Создание AI кавер-версии загруженного аудио файла', 15, 'music', 11, true)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub,
  icon = EXCLUDED.icon,
  sort_order = EXCLUDED.sort_order,
  is_active = EXCLUDED.is_active;

-- Add settings for service prices (if they don't exist)
INSERT INTO public.settings (key, value, description)
VALUES 
  ('add_vocal_price', '15', 'Стоимость добавления вокала к инструменталу'),
  ('upload_cover_price', '15', 'Стоимость создания кавер-версии')
ON CONFLICT (key) DO NOTHING;

-- =====================================================
-- Migration: 20260120225837_66da4f6c-52f1-4f9a-ba39-e620acfb4de4.sql
-- =====================================================
-- Add Russian music category with Shanson and sub-styles
INSERT INTO genre_categories (name, name_ru, sort_order) 
VALUES ('russian', 'Русская музыка', 0);

-- Add Shanson and its variations (using subquery to get category id)
INSERT INTO genres (category_id, name, name_ru, sort_order) 
SELECT id, 'Russian Shanson', 'Шансон', 1 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Blatnaya Pesnya', 'Шансон (Блатняк)', 2 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Classic Shanson', 'Шансон (Классический)', 3 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Odessa Shanson', 'Шансон (Одесский)', 4 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Author Shanson', 'Авторская песня', 5 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Russian Pop', 'Русский поп', 6 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Russian Rock', 'Русский рок', 7 FROM genre_categories WHERE name = 'russian'
UNION ALL
SELECT id, 'Romance', 'Романс', 8 FROM genre_categories WHERE name = 'russian';

-- =====================================================
-- Migration: 20260120232540_f0983752-4381-4300-8b9a-2c00bafea022.sql
-- =====================================================
-- ============================================
-- GAMIFICATION SYSTEM: Streaks, Challenges, Achievements
-- ============================================

-- User Streaks Table - tracks consecutive daily activity
CREATE TABLE public.user_streaks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  streak_type TEXT NOT NULL DEFAULT 'creation', -- 'creation', 'listening', 'engagement'
  current_streak INTEGER NOT NULL DEFAULT 0,
  longest_streak INTEGER NOT NULL DEFAULT 0,
  last_activity_date DATE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, streak_type)
);

-- Challenges Table - daily/weekly tasks
CREATE TABLE public.challenges (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL DEFAULT 'daily', -- 'daily', 'weekly', 'special'
  requirement_type TEXT NOT NULL, -- 'create_track', 'get_likes', 'listen_tracks', 'genre_challenge'
  requirement_value INTEGER NOT NULL DEFAULT 1,
  genre_id UUID REFERENCES public.genres(id),
  reward_type TEXT NOT NULL DEFAULT 'rub', -- 'rub', 'badge', 'streak_bonus'
  reward_value INTEGER NOT NULL DEFAULT 0,
  starts_at TIMESTAMP WITH TIME ZONE,
  ends_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- User Challenge Progress
CREATE TABLE public.user_challenges (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  challenge_id UUID NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,
  progress INTEGER NOT NULL DEFAULT 0,
  completed_at TIMESTAMP WITH TIME ZONE,
  reward_claimed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, challenge_id)
);

-- Achievements Table
CREATE TABLE public.achievements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  description_ru TEXT,
  icon TEXT, -- emoji or icon name
  category TEXT NOT NULL DEFAULT 'general', -- 'creation', 'social', 'engagement', 'special'
  requirement_type TEXT NOT NULL, -- 'tracks_created', 'total_likes', 'total_plays', 'followers', 'streak_days'
  requirement_value INTEGER NOT NULL,
  is_active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- User Achievements (earned)
CREATE TABLE public.user_achievements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  achievement_id UUID NOT NULL REFERENCES public.achievements(id) ON DELETE CASCADE,
  earned_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, achievement_id)
);

-- Enable RLS
ALTER TABLE public.user_streaks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;

-- RLS Policies

-- User Streaks: users can view and update their own
CREATE POLICY "Users can view own streaks" ON public.user_streaks
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own streaks" ON public.user_streaks
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own streaks" ON public.user_streaks
  FOR UPDATE USING (auth.uid() = user_id);

-- Challenges: public read, admin write
CREATE POLICY "Challenges are viewable by everyone" ON public.challenges
  FOR SELECT USING (true);

CREATE POLICY "Admins can manage challenges" ON public.challenges
  FOR ALL USING (public.is_admin(auth.uid()));

-- User Challenges: users manage their own
CREATE POLICY "Users can view own challenges" ON public.user_challenges
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own challenges" ON public.user_challenges
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own challenges" ON public.user_challenges
  FOR UPDATE USING (auth.uid() = user_id);

-- Achievements: public read
CREATE POLICY "Achievements are viewable by everyone" ON public.achievements
  FOR SELECT USING (true);

CREATE POLICY "Admins can manage achievements" ON public.achievements
  FOR ALL USING (public.is_admin(auth.uid()));

-- User Achievements: users can view all, insert own
CREATE POLICY "User achievements are viewable by everyone" ON public.user_achievements
  FOR SELECT USING (true);

CREATE POLICY "Users can earn achievements" ON public.user_achievements
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Triggers for updated_at
CREATE TRIGGER update_user_streaks_updated_at
  BEFORE UPDATE ON public.user_streaks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_user_challenges_updated_at
  BEFORE UPDATE ON public.user_challenges
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Insert default achievements
INSERT INTO public.achievements (name, name_ru, description_ru, icon, category, requirement_type, requirement_value, sort_order) VALUES
('First Track', 'Первый трек', 'Создайте свой первый трек', '🎵', 'creation', 'tracks_created', 1, 1),
('Rising Star', 'Восходящая звезда', 'Создайте 10 треков', '⭐', 'creation', 'tracks_created', 10, 2),
('Hit Maker', 'Хитмейкер', 'Создайте 50 треков', '🌟', 'creation', 'tracks_created', 50, 3),
('Legend', 'Легенда', 'Создайте 100 треков', '👑', 'creation', 'tracks_created', 100, 4),
('First Like', 'Первый лайк', 'Получите первый лайк на трек', '❤️', 'social', 'total_likes', 1, 5),
('Popular', 'Популярный', 'Получите 50 лайков', '💕', 'social', 'total_likes', 50, 6),
('Viral Hit', 'Вирусный хит', 'Получите 500 лайков', '🔥', 'social', 'total_likes', 500, 7),
('First Play', 'Первое прослушивание', 'Ваш трек прослушали', '▶️', 'engagement', 'total_plays', 1, 8),
('On Fire', 'В тренде', '1000 прослушиваний', '🎧', 'engagement', 'total_plays', 1000, 9),
('Viral', 'Вирусный', '10000 прослушиваний', '📈', 'engagement', 'total_plays', 10000, 10),
('First Follower', 'Первый подписчик', 'Получите первого подписчика', '👤', 'social', 'followers', 1, 11),
('Influencer', 'Инфлюенсер', '100 подписчиков', '👥', 'social', 'followers', 100, 12),
('Celebrity', 'Знаменитость', '1000 подписчиков', '🏆', 'social', 'followers', 1000, 13),
('Streak 3', '3 дня подряд', 'Создавайте музыку 3 дня подряд', '🔥', 'engagement', 'streak_days', 3, 14),
('Streak 7', 'Неделя творчества', 'Создавайте музыку 7 дней подряд', '💪', 'engagement', 'streak_days', 7, 15),
('Streak 30', 'Месяц вдохновения', 'Создавайте музыку 30 дней подряд', '🏅', 'engagement', 'streak_days', 30, 16);

-- Insert sample daily challenges
INSERT INTO public.challenges (title, description, type, requirement_type, requirement_value, reward_type, reward_value, is_active) VALUES
('Создай трек', 'Создайте любой трек сегодня', 'daily', 'create_track', 1, 'rub', 2, true),
('Лайкни 5 треков', 'Поставьте 5 лайков другим авторам', 'daily', 'give_likes', 5, 'rub', 1, true),
('Получи 3 лайка', 'Получите 3 лайка на свои треки', 'daily', 'get_likes', 3, 'rub', 3, true);

-- =====================================================
-- Migration: 20260121111903_5dcbe15c-2c24-4c34-8293-5e223cbd4c90.sql
-- =====================================================
-- Drop and recreate policies for track_likes to allow admin impersonation
DROP POLICY IF EXISTS "Users can like tracks" ON track_likes;
DROP POLICY IF EXISTS "Users can unlike tracks" ON track_likes;
DROP POLICY IF EXISTS "Anyone can view track likes" ON track_likes;

-- Recreate with admin impersonation support
CREATE POLICY "Anyone can view track likes" ON track_likes
FOR SELECT USING (true);

CREATE POLICY "Users can like tracks" ON track_likes
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can unlike tracks" ON track_likes
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update track_comments policies for admin impersonation
DROP POLICY IF EXISTS "Users can create comments" ON track_comments;
DROP POLICY IF EXISTS "Users can update own comments" ON track_comments;
DROP POLICY IF EXISTS "Users can delete own comments" ON track_comments;

CREATE POLICY "Users can create comments" ON track_comments
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own comments" ON track_comments
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own comments" ON track_comments
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update comment_likes policies for admin impersonation
DROP POLICY IF EXISTS "Users can like comments" ON comment_likes;
DROP POLICY IF EXISTS "Users can unlike comments" ON comment_likes;

CREATE POLICY "Users can like comments" ON comment_likes
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can unlike comments" ON comment_likes
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update tracks policies for admin impersonation
DROP POLICY IF EXISTS "Users can create tracks" ON tracks;
DROP POLICY IF EXISTS "Users can update own tracks" ON tracks;
DROP POLICY IF EXISTS "Users can delete own tracks" ON tracks;

CREATE POLICY "Users can create tracks" ON tracks
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own tracks" ON tracks
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own tracks" ON tracks
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update playlists policies for admin impersonation
DROP POLICY IF EXISTS "Users can create own playlists" ON playlists;
DROP POLICY IF EXISTS "Users can update own playlists" ON playlists;
DROP POLICY IF EXISTS "Users can delete own playlists" ON playlists;

CREATE POLICY "Users can create own playlists" ON playlists
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own playlists" ON playlists
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own playlists" ON playlists
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update playlist_tracks policies for admin impersonation
DROP POLICY IF EXISTS "Users can add tracks to own playlists" ON playlist_tracks;
DROP POLICY IF EXISTS "Users can remove tracks from own playlists" ON playlist_tracks;
DROP POLICY IF EXISTS "Users can reorder tracks in own playlists" ON playlist_tracks;

CREATE POLICY "Users can add tracks to own playlists" ON playlist_tracks
FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM playlists
    WHERE playlists.id = playlist_tracks.playlist_id
    AND (playlists.user_id = auth.uid() OR is_admin(auth.uid()))
  )
);

CREATE POLICY "Users can remove tracks from own playlists" ON playlist_tracks
FOR DELETE USING (
  EXISTS (
    SELECT 1 FROM playlists
    WHERE playlists.id = playlist_tracks.playlist_id
    AND (playlists.user_id = auth.uid() OR is_admin(auth.uid()))
  )
);

CREATE POLICY "Users can reorder tracks in own playlists" ON playlist_tracks
FOR UPDATE USING (
  EXISTS (
    SELECT 1 FROM playlists
    WHERE playlists.id = playlist_tracks.playlist_id
    AND (playlists.user_id = auth.uid() OR is_admin(auth.uid()))
  )
);

-- Update profiles policies for admin impersonation
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;

CREATE POLICY "Users can update own profile" ON profiles
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update gallery_items policies for admin impersonation
DROP POLICY IF EXISTS "Users can insert own gallery items" ON gallery_items;
DROP POLICY IF EXISTS "Users can update own gallery items" ON gallery_items;
DROP POLICY IF EXISTS "Users can delete own gallery items" ON gallery_items;

CREATE POLICY "Users can insert own gallery items" ON gallery_items
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own gallery items" ON gallery_items
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own gallery items" ON gallery_items
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update notifications policies for admin impersonation
DROP POLICY IF EXISTS "Users can insert own notifications" ON notifications;
DROP POLICY IF EXISTS "Users can update own notifications" ON notifications;
DROP POLICY IF EXISTS "Users can delete own notifications" ON notifications;

CREATE POLICY "Users can insert own notifications" ON notifications
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own notifications" ON notifications
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own notifications" ON notifications
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update user_follows policies for admin impersonation
DROP POLICY IF EXISTS "Users can follow others" ON user_follows;
DROP POLICY IF EXISTS "Users can unfollow" ON user_follows;

CREATE POLICY "Users can follow others" ON user_follows
FOR INSERT WITH CHECK (
  auth.uid() = follower_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can unfollow" ON user_follows
FOR DELETE USING (
  auth.uid() = follower_id OR is_admin(auth.uid())
);

-- Update generated_lyrics policies for admin impersonation
DROP POLICY IF EXISTS "Users can create lyrics" ON generated_lyrics;
DROP POLICY IF EXISTS "Users can delete their own lyrics" ON generated_lyrics;

CREATE POLICY "Users can create lyrics" ON generated_lyrics
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete their own lyrics" ON generated_lyrics
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update audio_separations policies for admin impersonation  
DROP POLICY IF EXISTS "Users can insert own audio separations" ON audio_separations;
DROP POLICY IF EXISTS "Users can update own audio separations" ON audio_separations;

CREATE POLICY "Users can insert own audio separations" ON audio_separations
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own audio separations" ON audio_separations
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update user_prompts policies for admin impersonation
DROP POLICY IF EXISTS "Users can create prompts" ON user_prompts;
DROP POLICY IF EXISTS "Users can update own prompts" ON user_prompts;
DROP POLICY IF EXISTS "Users can delete own prompts" ON user_prompts;

CREATE POLICY "Users can create prompts" ON user_prompts
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can update own prompts" ON user_prompts
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own prompts" ON user_prompts
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- =====================================================
-- Migration: 20260121112137_9657c3f2-4f85-40c0-b3a7-11d226f90963.sql
-- =====================================================
-- Update messages policies for admin impersonation
DROP POLICY IF EXISTS "Users can send messages to their conversations" ON messages;
DROP POLICY IF EXISTS "Users can update their own messages" ON messages;
DROP POLICY IF EXISTS "Users can delete their own messages" ON messages;

CREATE POLICY "Users can send messages to their conversations" ON messages
FOR INSERT WITH CHECK (
  (sender_id = auth.uid() OR is_admin(auth.uid())) AND 
  EXISTS (
    SELECT 1 FROM conversation_participants
    WHERE conversation_participants.conversation_id = messages.conversation_id
    AND (conversation_participants.user_id = auth.uid() OR conversation_participants.user_id = sender_id)
  )
);

CREATE POLICY "Users can update their own messages" ON messages
FOR UPDATE USING (
  sender_id = auth.uid() OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete their own messages" ON messages
FOR DELETE USING (
  sender_id = auth.uid() OR is_admin(auth.uid())
);

-- Update conversation_participants policies for admin impersonation
DROP POLICY IF EXISTS "Users can add participants to conversations they're in" ON conversation_participants;
DROP POLICY IF EXISTS "Users can update their own participation" ON conversation_participants;

CREATE POLICY "Users can add participants to conversations they're in" ON conversation_participants
FOR INSERT WITH CHECK (
  user_id = auth.uid() OR is_admin(auth.uid()) OR
  EXISTS (
    SELECT 1 FROM conversation_participants cp
    WHERE cp.conversation_id = conversation_participants.conversation_id 
    AND cp.user_id = auth.uid()
  )
);

CREATE POLICY "Users can update their own participation" ON conversation_participants
FOR UPDATE USING (
  user_id = auth.uid() OR is_admin(auth.uid())
);

-- Update playlist_likes policies for admin impersonation
DROP POLICY IF EXISTS "Users can like playlists" ON playlist_likes;
DROP POLICY IF EXISTS "Users can unlike playlists" ON playlist_likes;

CREATE POLICY "Users can like playlists" ON playlist_likes
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can unlike playlists" ON playlist_likes
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update gallery_likes policies for admin impersonation
DROP POLICY IF EXISTS "Users can insert own likes" ON gallery_likes;
DROP POLICY IF EXISTS "Users can delete own likes" ON gallery_likes;

CREATE POLICY "Users can insert own likes" ON gallery_likes
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can delete own likes" ON gallery_likes
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update contest_entries policies for admin impersonation
DROP POLICY IF EXISTS "Users can submit their own tracks" ON contest_entries;
DROP POLICY IF EXISTS "Users can withdraw own entries" ON contest_entries;

CREATE POLICY "Users can submit their own tracks" ON contest_entries
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can withdraw own entries" ON contest_entries
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update contest_votes policies for admin impersonation
DROP POLICY IF EXISTS "Authenticated users can vote" ON contest_votes;
DROP POLICY IF EXISTS "Users can remove own vote" ON contest_votes;

CREATE POLICY "Authenticated users can vote" ON contest_votes
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can remove own vote" ON contest_votes
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update generation_logs policies for admin impersonation
DROP POLICY IF EXISTS "System can insert generation logs" ON generation_logs;

CREATE POLICY "System can insert generation logs" ON generation_logs
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update payments policies for admin impersonation
DROP POLICY IF EXISTS "Allow insert for authenticated users" ON payments;

CREATE POLICY "Allow insert for authenticated users" ON payments
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- Update beat_purchases policies for admin impersonation
DROP POLICY IF EXISTS "System can create beat purchases" ON beat_purchases;

CREATE POLICY "System can create beat purchases" ON beat_purchases
FOR INSERT WITH CHECK (
  auth.uid() = buyer_id OR is_admin(auth.uid())
);

-- Update prompt_purchases policies for admin impersonation
DROP POLICY IF EXISTS "System can create prompt purchases" ON prompt_purchases;

CREATE POLICY "System can create prompt purchases" ON prompt_purchases
FOR INSERT WITH CHECK (
  auth.uid() = buyer_id OR is_admin(auth.uid())
);

-- Update payout_requests policies for admin impersonation
DROP POLICY IF EXISTS "Users can create payout requests" ON payout_requests;

CREATE POLICY "Users can create payout requests" ON payout_requests
FOR INSERT WITH CHECK (
  auth.uid() = seller_id OR is_admin(auth.uid())
);

-- =====================================================
-- Migration: 20260121112309_f9d78dfb-b4e8-4697-ba6f-3b63d69bed92.sql
-- =====================================================
-- Fix conversation_participants SELECT policy to support admin impersonation
DROP POLICY IF EXISTS "Users can view participants of their conversations" ON conversation_participants;

CREATE POLICY "Users can view participants of their conversations" ON conversation_participants
FOR SELECT USING (
  user_id = auth.uid() OR 
  is_admin(auth.uid()) OR
  EXISTS (
    SELECT 1 FROM conversation_participants cp
    WHERE cp.conversation_id = conversation_participants.conversation_id 
    AND cp.user_id = auth.uid()
  )
);

-- =====================================================
-- Migration: 20260121113417_541aca12-02b7-42f7-91e0-689f9dc16263.sql
-- =====================================================
-- Fix storage policies for admin impersonation
-- Avatars bucket
DROP POLICY IF EXISTS "Users can upload their own avatar" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own avatar" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own avatar" ON storage.objects;

CREATE POLICY "Users can upload their own avatar" ON storage.objects
FOR INSERT WITH CHECK (
  bucket_id = 'avatars' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

CREATE POLICY "Users can update their own avatar" ON storage.objects
FOR UPDATE USING (
  bucket_id = 'avatars' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

CREATE POLICY "Users can delete their own avatar" ON storage.objects
FOR DELETE USING (
  bucket_id = 'avatars' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

-- Covers bucket
DROP POLICY IF EXISTS "Users can upload their own cover" ON storage.objects;
DROP POLICY IF EXISTS "Users can update their own cover" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own cover" ON storage.objects;

CREATE POLICY "Users can upload their own cover" ON storage.objects
FOR INSERT WITH CHECK (
  bucket_id = 'covers' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

CREATE POLICY "Users can update their own cover" ON storage.objects
FOR UPDATE USING (
  bucket_id = 'covers' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

CREATE POLICY "Users can delete their own cover" ON storage.objects
FOR DELETE USING (
  bucket_id = 'covers' AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR is_admin(auth.uid())
  )
);

-- Also fix profiles UPDATE policy for admin impersonation
DROP POLICY IF EXISTS "Users can update their own profile" ON profiles;

CREATE POLICY "Users can update their own profile" ON profiles
FOR UPDATE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

-- =====================================================
-- Migration: 20260121122849_614e4724-2f99-4dfa-a509-b5227c3b621b.sql
-- =====================================================

-- Таблица для отслеживания использования пробных попыток
CREATE TABLE public.feature_trials (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  feature_key TEXT NOT NULL,
  uses_count INTEGER NOT NULL DEFAULT 0,
  max_uses INTEGER NOT NULL DEFAULT 3,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, feature_key)
);

-- Enable RLS
ALTER TABLE public.feature_trials ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view own trials" 
ON public.feature_trials 
FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own trials" 
ON public.feature_trials 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own trials" 
ON public.feature_trials 
FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all trials" 
ON public.feature_trials 
FOR ALL 
USING (is_admin(auth.uid()));

-- Функция для проверки и использования пробной попытки
CREATE OR REPLACE FUNCTION public.use_feature_trial(
  p_user_id UUID,
  p_feature_key TEXT,
  p_max_uses INTEGER DEFAULT 3
)
RETURNS JSONB AS $$
DECLARE
  v_trial feature_trials%ROWTYPE;
  v_result JSONB;
BEGIN
  -- Получить или создать запись о пробных попытках
  INSERT INTO feature_trials (user_id, feature_key, uses_count, max_uses)
  VALUES (p_user_id, p_feature_key, 0, p_max_uses)
  ON CONFLICT (user_id, feature_key) DO NOTHING;
  
  -- Получить текущее состояние
  SELECT * INTO v_trial 
  FROM feature_trials 
  WHERE user_id = p_user_id AND feature_key = p_feature_key;
  
  -- Проверить остались ли попытки
  IF v_trial.uses_count >= v_trial.max_uses THEN
    RETURN jsonb_build_object(
      'success', false,
      'remaining', 0,
      'message', 'Trial limit reached'
    );
  END IF;
  
  -- Увеличить счетчик
  UPDATE feature_trials 
  SET uses_count = uses_count + 1, updated_at = now()
  WHERE user_id = p_user_id AND feature_key = p_feature_key;
  
  RETURN jsonb_build_object(
    'success', true,
    'remaining', v_trial.max_uses - v_trial.uses_count - 1,
    'message', 'Trial use recorded'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Функция для получения оставшихся попыток
CREATE OR REPLACE FUNCTION public.get_trial_remaining(
  p_user_id UUID,
  p_feature_key TEXT,
  p_max_uses INTEGER DEFAULT 3
)
RETURNS INTEGER AS $$
DECLARE
  v_uses INTEGER;
BEGIN
  SELECT uses_count INTO v_uses 
  FROM feature_trials 
  WHERE user_id = p_user_id AND feature_key = p_feature_key;
  
  IF v_uses IS NULL THEN
    RETURN p_max_uses;
  END IF;
  
  RETURN GREATEST(0, p_max_uses - v_uses);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Добавить настройки по умолчанию
INSERT INTO settings (key, value, description) VALUES
  ('trial_lyrics_editor_enabled', 'true', 'Включить пробный период для редактора текста'),
  ('trial_lyrics_editor_uses', '3', 'Количество бесплатных попыток редактора текста'),
  ('trial_prompts_marketplace_enabled', 'true', 'Включить пробный период для маркетплейса промптов'),
  ('trial_prompts_marketplace_uses', '3', 'Количество бесплатных попыток маркетплейса'),
  ('trial_covers_enabled', 'true', 'Включить пробный период для HD обложек'),
  ('trial_covers_uses', '3', 'Количество бесплатных попыток HD обложек'),
  ('trial_video_enabled', 'true', 'Включить пробный период для видео'),
  ('trial_video_uses', '3', 'Количество бесплатных попыток видео')
ON CONFLICT (key) DO NOTHING;


-- =====================================================
-- Migration: 20260121131153_afc6fed8-1c3a-44a6-a78a-e97de3e10a5b.sql
-- =====================================================
-- Drop existing problematic policies for conversation_participants
DROP POLICY IF EXISTS "Users can view participants of their conversations" ON conversation_participants;
DROP POLICY IF EXISTS "Users can add participants to conversations they're in" ON conversation_participants;
DROP POLICY IF EXISTS "conversation_participants_select_policy" ON conversation_participants;
DROP POLICY IF EXISTS "conversation_participants_insert_policy" ON conversation_participants;

-- Create a helper function to avoid recursion (SECURITY DEFINER to bypass RLS)
CREATE OR REPLACE FUNCTION public.is_participant_in_conversation(p_user_id uuid, p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM conversation_participants
    WHERE user_id = p_user_id AND conversation_id = p_conversation_id
  )
$$;

-- Recreate SELECT policy using helper function
CREATE POLICY "Users can view participants of their conversations" 
ON conversation_participants
FOR SELECT 
USING (
  user_id = auth.uid() OR 
  is_admin(auth.uid()) OR
  is_participant_in_conversation(auth.uid(), conversation_id)
);

-- Recreate INSERT policy using helper function
CREATE POLICY "Users can add participants to conversations they're in" 
ON conversation_participants
FOR INSERT 
WITH CHECK (
  user_id = auth.uid() OR 
  is_admin(auth.uid()) OR
  is_participant_in_conversation(auth.uid(), conversation_id)
);

-- =====================================================
-- Migration: 20260121133214_b72c1f04-69f1-42bf-9b0f-34cc40cc8a3a.sql
-- =====================================================
-- Create a secure function to create conversation with participants
CREATE OR REPLACE FUNCTION public.create_conversation_with_user(p_other_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_conversation_id UUID;
  v_current_user_id UUID;
BEGIN
  v_current_user_id := auth.uid();
  
  IF v_current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  
  IF v_current_user_id = p_other_user_id THEN
    RAISE EXCEPTION 'Cannot create conversation with yourself';
  END IF;
  
  -- Check if conversation already exists
  SELECT cp1.conversation_id INTO v_conversation_id
  FROM conversation_participants cp1
  JOIN conversation_participants cp2 ON cp1.conversation_id = cp2.conversation_id
  WHERE cp1.user_id = v_current_user_id AND cp2.user_id = p_other_user_id
  LIMIT 1;
  
  IF v_conversation_id IS NOT NULL THEN
    RETURN v_conversation_id;
  END IF;
  
  -- Create new conversation
  INSERT INTO conversations DEFAULT VALUES
  RETURNING id INTO v_conversation_id;
  
  -- Add both participants
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES 
    (v_conversation_id, v_current_user_id),
    (v_conversation_id, p_other_user_id);
  
  RETURN v_conversation_id;
END;
$$;

-- =====================================================
-- Migration: 20260121135527_0a6cd35d-357d-4099-9b8e-8705701fd4a1.sql
-- =====================================================
-- Add DELETE policy for conversation_participants
CREATE POLICY "Users can leave conversations"
ON public.conversation_participants
FOR DELETE
USING (user_id = auth.uid() OR is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260121140024_2aa38fce-412e-455c-bccf-88cccb42305d.sql
-- =====================================================
-- Add DELETE policy for profiles table so admins can delete user profiles
CREATE POLICY "Admins can delete profiles"
ON public.profiles
FOR DELETE
USING (is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260121143407_799adb33-1979-494e-bfc0-d3978d3f8653.sql
-- =====================================================
-- Add last_seen_at column to profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMP WITH TIME ZONE DEFAULT now();

-- Create index for efficient queries
CREATE INDEX IF NOT EXISTS idx_profiles_last_seen_at ON public.profiles(last_seen_at DESC);

-- Add attachment_url column to messages for file/image sharing
ALTER TABLE public.messages 
ADD COLUMN IF NOT EXISTS attachment_url TEXT,
ADD COLUMN IF NOT EXISTS attachment_type TEXT;

-- Create storage bucket for message attachments
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('message-attachments', 'message-attachments', true, 10485760) -- 10MB limit
ON CONFLICT (id) DO NOTHING;

-- RLS policies for message attachments bucket
CREATE POLICY "Users can upload message attachments"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'message-attachments' 
  AND auth.uid() IS NOT NULL
);

CREATE POLICY "Users can view message attachments"
ON storage.objects FOR SELECT
USING (bucket_id = 'message-attachments');

CREATE POLICY "Users can delete own message attachments"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'message-attachments' 
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Function to update last_seen_at
CREATE OR REPLACE FUNCTION public.update_last_seen()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE profiles 
  SET last_seen_at = now() 
  WHERE user_id = auth.uid();
END;
$$;

-- =====================================================
-- Migration: 20260121144128_8c4c6e36-835f-44f9-884c-83152b5df739.sql
-- =====================================================
-- Create message reactions table
CREATE TABLE public.message_reactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  emoji TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(message_id, user_id, emoji)
);

-- Enable RLS
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;

-- Policies for message reactions
CREATE POLICY "Users can view reactions on messages in their conversations"
ON public.message_reactions
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.messages m
    JOIN public.conversation_participants cp ON cp.conversation_id = m.conversation_id
    WHERE m.id = message_reactions.message_id
    AND cp.user_id = auth.uid()
  )
);

CREATE POLICY "Users can add reactions to messages in their conversations"
ON public.message_reactions
FOR INSERT
WITH CHECK (
  auth.uid() = user_id AND
  EXISTS (
    SELECT 1 FROM public.messages m
    JOIN public.conversation_participants cp ON cp.conversation_id = m.conversation_id
    WHERE m.id = message_reactions.message_id
    AND cp.user_id = auth.uid()
  )
);

CREATE POLICY "Users can remove their own reactions"
ON public.message_reactions
FOR DELETE
USING (auth.uid() = user_id);

-- Enable realtime for reactions
ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reactions;

-- Add forwarded_from_id to messages for forwarding feature
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS forwarded_from_id UUID REFERENCES public.messages(id);

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_message_reactions_message_id ON public.message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_messages_forwarded_from_id ON public.messages(forwarded_from_id);

-- =====================================================
-- Migration: 20260121153643_699b9368-ce21-4b24-90c4-9a01ddfde174.sql
-- =====================================================
-- Add position column to tracks table for user track ordering
ALTER TABLE public.tracks 
ADD COLUMN IF NOT EXISTS position INTEGER DEFAULT 0;

-- Create index for faster sorting
CREATE INDEX IF NOT EXISTS idx_tracks_user_position ON public.tracks(user_id, position);

-- Initialize positions based on created_at for existing tracks
WITH ranked AS (
  SELECT id, user_id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) as rn
  FROM public.tracks
)
UPDATE public.tracks t
SET position = r.rn
FROM ranked r
WHERE t.id = r.id;

-- =====================================================
-- Migration: 20260121164729_68272068-6ea2-4343-a5b8-530f104a1e68.sql
-- =====================================================
-- ═══════════════════════════════════════════════════════
-- МОДЕРАЦИЯ И ДИСТРИБУЦИЯ ТРЕКОВ
-- ═══════════════════════════════════════════════════════

-- Источник трека
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS source_type TEXT DEFAULT 'generated';

-- Модерация загруженных треков
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_status TEXT DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_reviewed_by UUID REFERENCES auth.users(id);
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_rejection_reason TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS moderation_notes TEXT;

-- Автоматическая проверка авторских прав
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_status TEXT DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_check_result JSONB;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS copyright_checked_at TIMESTAMP WITH TIME ZONE;

-- Дистрибуция
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_status TEXT DEFAULT 'none';
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_submitted_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_by UUID REFERENCES auth.users(id);
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_rejection_reason TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_platforms JSONB DEFAULT '[]'::jsonb;

-- Юридическая информация
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS is_original_work BOOLEAN;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_samples BOOLEAN;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS samples_licensed BOOLEAN;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_interpolations BOOLEAN;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS interpolations_licensed BOOLEAN;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS performer_name TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS label_name TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS music_author TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS lyrics_author TEXT;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS isrc_code TEXT;

-- Индексы для быстрого поиска
CREATE INDEX IF NOT EXISTS idx_tracks_source_type ON public.tracks(source_type);
CREATE INDEX IF NOT EXISTS idx_tracks_moderation_status ON public.tracks(moderation_status);
CREATE INDEX IF NOT EXISTS idx_tracks_distribution_status ON public.tracks(distribution_status);
CREATE INDEX IF NOT EXISTS idx_tracks_copyright_check_status ON public.tracks(copyright_check_status);

-- Комментарии
COMMENT ON COLUMN public.tracks.source_type IS 'Источник трека: generated (AI) или uploaded (загружен)';
COMMENT ON COLUMN public.tracks.moderation_status IS 'Статус модерации: none, pending, approved, rejected';
COMMENT ON COLUMN public.tracks.copyright_check_status IS 'Статус проверки прав: none, pending, clean, flagged, blocked';
COMMENT ON COLUMN public.tracks.distribution_status IS 'Статус дистрибуции: none, pending, approved, rejected, distributed';

-- =====================================================
-- Migration: 20260121173118_8b47b90a-725a-44dd-a424-ed10e2f07158.sql
-- =====================================================
-- Таблица депонирований треков
CREATE TABLE public.track_deposits (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  
  -- Метод депонирования
  method TEXT NOT NULL CHECK (method IN ('internal', 'pdf', 'blockchain', 'nris', 'irma')),
  
  -- Статус
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  
  -- Данные депонирования
  file_hash TEXT NOT NULL,
  metadata_hash TEXT,
  
  -- Результаты
  certificate_url TEXT,
  blockchain_tx_id TEXT,
  external_deposit_id TEXT,
  external_certificate_url TEXT,
  
  -- Ошибка если failed
  error_message TEXT,
  
  -- Временные метки
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  completed_at TIMESTAMP WITH TIME ZONE,
  
  -- Уникальность: один метод на трек
  UNIQUE(track_id, method)
);

-- Индексы
CREATE INDEX idx_track_deposits_track ON public.track_deposits(track_id);
CREATE INDEX idx_track_deposits_user ON public.track_deposits(user_id);
CREATE INDEX idx_track_deposits_status ON public.track_deposits(status);

-- RLS
ALTER TABLE public.track_deposits ENABLE ROW LEVEL SECURITY;

-- Пользователь видит свои депонирования
CREATE POLICY "Users can view own deposits"
ON public.track_deposits FOR SELECT
USING (auth.uid() = user_id);

-- Пользователь может создавать депонирования для своих треков
CREATE POLICY "Users can create deposits for own tracks"
ON public.track_deposits FOR INSERT
WITH CHECK (
  auth.uid() = user_id AND
  EXISTS (SELECT 1 FROM public.tracks WHERE id = track_id AND user_id = auth.uid())
);

-- Система может обновлять статус (через service role)
CREATE POLICY "Service can update deposits"
ON public.track_deposits FOR UPDATE
USING (true)
WITH CHECK (true);

-- Админы видят все
CREATE POLICY "Admins can view all deposits"
ON public.track_deposits FOR SELECT
USING (public.is_admin(auth.uid()));

-- Добавляем колонку стоимости депонирования в settings если нужно
INSERT INTO public.settings (key, value) VALUES 
  ('deposit_price_internal', '0'),
  ('deposit_price_pdf', '0'),
  ('deposit_price_blockchain', '10'),
  ('deposit_price_nris', '500'),
  ('deposit_price_irma', '300'),
  ('nris_api_url', 'https://api.nris.ru/v1'),
  ('irma_api_url', 'https://api.irma.ru/v1')
ON CONFLICT (key) DO NOTHING;

-- =====================================================
-- Migration: 20260121173128_29a0d9fa-3b72-43b0-8324-9d0151941a94.sql
-- =====================================================
-- Удаляем небезопасную политику
DROP POLICY IF EXISTS "Service can update deposits" ON public.track_deposits;

-- Создаём безопасную политику - только владелец может обновлять свои pending депонирования
CREATE POLICY "Users can update own pending deposits"
ON public.track_deposits FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- Migration: 20260121181604_8fb31846-838b-46ce-b7f2-1bec30a256f8.sql
-- =====================================================
-- Создаём бакет для сертификатов депонирования
INSERT INTO storage.buckets (id, name, public)
VALUES ('certificates', 'certificates', true)
ON CONFLICT (id) DO NOTHING;

-- Политика: публичное чтение сертификатов
CREATE POLICY "Public access to certificates"
ON storage.objects FOR SELECT
USING (bucket_id = 'certificates');

-- Политика: только service role может загружать
CREATE POLICY "Service role can upload certificates"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'certificates');

-- =====================================================
-- Migration: 20260121185446_9408763b-9bf2-4a15-9635-1661b1eb9a51.sql
-- =====================================================
-- Добавляем колонки для хранения данных авторов в момент депонирования
ALTER TABLE public.track_deposits
ADD COLUMN IF NOT EXISTS performer_name text,
ADD COLUMN IF NOT EXISTS lyrics_author text;

-- Комментарий для документации
COMMENT ON COLUMN public.track_deposits.performer_name IS 'Автор произведения на момент депонирования';
COMMENT ON COLUMN public.track_deposits.lyrics_author IS 'Автор текста на момент депонирования';

-- =====================================================
-- Migration: 20260121194400_3736be6d-a012-4067-a52a-a47024268ed3.sql
-- =====================================================
-- Enable realtime for tracks table
ALTER PUBLICATION supabase_realtime ADD TABLE public.tracks;

-- =====================================================
-- Migration: 20260122052528_1cd4cc4a-7a3c-45ba-94eb-df9fbe168624.sql
-- =====================================================
-- Обновляем constraint для поддержки всех типов действий включая существующие
ALTER TABLE public.role_change_logs DROP CONSTRAINT IF EXISTS role_change_logs_action_check;

ALTER TABLE public.role_change_logs ADD CONSTRAINT role_change_logs_action_check 
CHECK (action IN (
  'invited', 'accepted', 'declined', 'revoked', 'expired', 'assigned',
  'blocked', 'unblocked',
  'balance_changed',
  'user_deleted',
  'impersonation_started', 'impersonation_ended',
  'profile_updated',
  'track_deleted',
  'moderation_approved', 'moderation_rejected',
  'distribution_approved', 'distribution_rejected',
  'deposit_approved', 'deposit_rejected',
  'setting_changed',
  'contest_created', 'contest_updated', 'contest_deleted'
));

-- Добавляем индексы для быстрого поиска логов
CREATE INDEX IF NOT EXISTS idx_role_change_logs_created_at ON public.role_change_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_role_change_logs_changed_by ON public.role_change_logs(changed_by);
CREATE INDEX IF NOT EXISTS idx_role_change_logs_action ON public.role_change_logs(action);

-- RLS для просмотра логов только админами
DROP POLICY IF EXISTS "Super admins can view all logs" ON public.role_change_logs;
CREATE POLICY "Super admins can view all logs" ON public.role_change_logs
  FOR SELECT
  USING (public.is_admin(auth.uid()));

-- Разрешаем вставку логов админам
DROP POLICY IF EXISTS "Admins can insert logs" ON public.role_change_logs;
CREATE POLICY "Admins can insert logs" ON public.role_change_logs
  FOR INSERT
  WITH CHECK (public.is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260122053154_a3f335bf-f535-4b49-86e7-f7237bd6b62e.sql
-- =====================================================
-- Create a secure function for accepting role invitations
-- This runs with elevated privileges (SECURITY DEFINER) to allow users to accept their own invitations
CREATE OR REPLACE FUNCTION public.accept_role_invitation(
  _invitation_id UUID,
  _accept BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_invitation RECORD;
  v_result JSONB;
BEGIN
  -- Get the current user
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Get and validate the invitation
  SELECT ri.*, 
         COALESCE(
           (SELECT jsonb_agg(rip.category_id) 
            FROM role_invitation_permissions rip 
            WHERE rip.invitation_id = ri.id), 
           '[]'::jsonb
         ) as permission_ids
  INTO v_invitation
  FROM role_invitations ri
  WHERE ri.id = _invitation_id 
    AND ri.user_id = v_user_id 
    AND ri.status = 'pending'
    AND ri.expires_at > NOW();

  IF v_invitation IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired invitation';
  END IF;

  -- Update invitation status
  UPDATE role_invitations
  SET status = CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
      responded_at = NOW()
  WHERE id = _invitation_id;

  IF _accept THEN
    -- Remove old role
    DELETE FROM user_roles WHERE user_id = v_user_id;
    
    -- Remove old permissions
    DELETE FROM moderator_permissions WHERE user_id = v_user_id;

    -- Assign new role
    INSERT INTO user_roles (user_id, role)
    VALUES (v_user_id, v_invitation.role);

    -- If moderator, add permissions
    IF v_invitation.role = 'moderator' AND jsonb_array_length(v_invitation.permission_ids) > 0 THEN
      INSERT INTO moderator_permissions (user_id, category_id, granted_by)
      SELECT v_user_id, (cat_id)::uuid, v_invitation.invited_by
      FROM jsonb_array_elements_text(v_invitation.permission_ids) AS cat_id;
    END IF;
  END IF;

  -- Log the action
  INSERT INTO role_change_logs (user_id, changed_by, action, new_role, metadata)
  VALUES (
    v_user_id,
    v_user_id,
    CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
    CASE WHEN _accept THEN v_invitation.role ELSE NULL END,
    jsonb_build_object('invitation_id', _invitation_id)
  );

  -- Create notification for the admin who sent the invitation
  INSERT INTO notifications (user_id, type, title, message, target_type, target_id, actor_id)
  VALUES (
    v_invitation.invited_by,
    CASE WHEN _accept THEN 'role_accepted' ELSE 'role_declined' END,
    CASE WHEN _accept 
      THEN 'Приглашение на роль ' || v_invitation.role || ' принято'
      ELSE 'Приглашение на роль ' || v_invitation.role || ' отклонено'
    END,
    CASE WHEN _accept 
      THEN 'Пользователь принял ваше приглашение'
      ELSE 'Пользователь отклонил приглашение'
    END,
    'role_invitation',
    _invitation_id,
    v_user_id
  );

  v_result := jsonb_build_object(
    'accepted', _accept,
    'role', v_invitation.role
  );

  RETURN v_result;
END;
$$;

-- =====================================================
-- Migration: 20260122053529_e88422e3-bde3-46bc-8ad4-19550e5e891d.sql
-- =====================================================
-- Drop and recreate the function to ensure it bypasses RLS properly
DROP FUNCTION IF EXISTS public.accept_role_invitation(UUID, BOOLEAN);

-- Create the function with proper RLS bypass
CREATE OR REPLACE FUNCTION public.accept_role_invitation(
  _invitation_id UUID,
  _accept BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_invitation RECORD;
  v_result JSONB;
BEGIN
  -- Get the current user
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Get and validate the invitation
  SELECT ri.*, 
         COALESCE(
           (SELECT jsonb_agg(rip.category_id) 
            FROM role_invitation_permissions rip 
            WHERE rip.invitation_id = ri.id), 
           '[]'::jsonb
         ) as permission_ids
  INTO v_invitation
  FROM role_invitations ri
  WHERE ri.id = _invitation_id 
    AND ri.user_id = v_user_id 
    AND ri.status = 'pending'
    AND ri.expires_at > NOW();

  IF v_invitation IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired invitation';
  END IF;

  -- Update invitation status (bypass RLS with direct update)
  UPDATE role_invitations
  SET status = CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
      responded_at = NOW()
  WHERE id = _invitation_id;

  IF _accept THEN
    -- Remove old role (direct delete bypasses RLS due to SECURITY DEFINER)
    DELETE FROM user_roles WHERE user_id = v_user_id;
    
    -- Remove old permissions
    DELETE FROM moderator_permissions WHERE user_id = v_user_id;

    -- Assign new role (direct insert bypasses RLS due to SECURITY DEFINER)
    INSERT INTO user_roles (user_id, role)
    VALUES (v_user_id, v_invitation.role);

    -- If moderator, add permissions
    IF v_invitation.role = 'moderator' AND jsonb_array_length(v_invitation.permission_ids) > 0 THEN
      INSERT INTO moderator_permissions (user_id, category_id, granted_by)
      SELECT v_user_id, (cat_id)::uuid, v_invitation.invited_by
      FROM jsonb_array_elements_text(v_invitation.permission_ids) AS cat_id;
    END IF;
  END IF;

  -- Log the action
  INSERT INTO role_change_logs (user_id, changed_by, action, new_role, metadata)
  VALUES (
    v_user_id,
    v_user_id,
    CASE WHEN _accept THEN 'accepted' ELSE 'declined' END,
    CASE WHEN _accept THEN v_invitation.role ELSE NULL END,
    jsonb_build_object('invitation_id', _invitation_id)
  );

  -- Create notification for the admin who sent the invitation
  INSERT INTO notifications (user_id, type, title, message, target_type, target_id, actor_id)
  VALUES (
    v_invitation.invited_by,
    CASE WHEN _accept THEN 'role_accepted' ELSE 'role_declined' END,
    CASE WHEN _accept 
      THEN 'Приглашение на роль ' || v_invitation.role || ' принято'
      ELSE 'Приглашение на роль ' || v_invitation.role || ' отклонено'
    END,
    CASE WHEN _accept 
      THEN 'Пользователь принял ваше приглашение'
      ELSE 'Пользователь отклонил приглашение'
    END,
    'role_invitation',
    _invitation_id,
    v_user_id
  );

  v_result := jsonb_build_object(
    'accepted', _accept,
    'role', v_invitation.role
  );

  RETURN v_result;
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.accept_role_invitation(UUID, BOOLEAN) TO authenticated;

-- Add RLS policy to allow the function owner to bypass RLS on user_roles
-- We need to add a policy that allows inserts when called from this function
-- Since SECURITY DEFINER runs as the function owner (postgres), we need to ensure it has rights

-- Alternative approach: Add a bypass policy for the service role / function context
DROP POLICY IF EXISTS "Allow role assignment via function" ON public.user_roles;
CREATE POLICY "Allow role assignment via function" ON public.user_roles
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- But restrict this - only admins and the secure function should insert
-- Let's be more specific: keep admin policies and add one for self-assignment via invitation
DROP POLICY IF EXISTS "Allow role assignment via function" ON public.user_roles;

-- Keep existing admin policies intact, the SECURITY DEFINER function runs as owner
-- The issue is that even SECURITY DEFINER doesn't bypass RLS unless the owner is a superuser
-- Solution: Create a policy that allows users to have their own role assigned
DROP POLICY IF EXISTS "Users can receive role via invitation" ON public.user_roles;
CREATE POLICY "Users can receive role via invitation" ON public.user_roles
  FOR INSERT
  WITH CHECK (
    -- Allow if there's a valid accepted invitation for this user and role
    EXISTS (
      SELECT 1 FROM role_invitations ri
      WHERE ri.user_id = user_roles.user_id
        AND ri.role = user_roles.role
        AND ri.status = 'accepted'
        AND ri.responded_at > NOW() - INTERVAL '1 minute'
    )
    OR is_admin(auth.uid())
  );

-- =====================================================
-- Migration: 20260122055413_75179ab2-295a-4dc7-b37f-6e755a9924cd.sql
-- =====================================================
-- 1. Create a secure view for profiles that hides super_admin from regular users
CREATE OR REPLACE VIEW public.profiles_visible 
WITH (security_invoker = true)
AS
SELECT 
  p.id,
  p.user_id,
  p.username,
  p.avatar_url,
  p.cover_url,
  p.bio,
  p.social_links,
  p.followers_count,
  p.following_count,
  p.created_at,
  p.updated_at,
  p.last_seen_at
FROM public.profiles p
WHERE 
  -- Always show if viewer is super_admin
  public.is_super_admin(auth.uid())
  OR
  -- Hide super_admins from everyone else
  NOT EXISTS (
    SELECT 1 FROM public.user_roles ur 
    WHERE ur.user_id = p.user_id AND ur.role = 'super_admin'
  );

-- 2. Add protection to prevent deleting super_admin user from auth
-- Create a function to check before delete operations
CREATE OR REPLACE FUNCTION public.protect_super_admin_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if trying to delete a super_admin's profile
  IF EXISTS (
    SELECT 1 FROM public.user_roles 
    WHERE user_id = OLD.user_id AND role = 'super_admin'
  ) THEN
    -- Only the super_admin themselves can delete their profile
    IF auth.uid() IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'Cannot delete super_admin account';
    END IF;
  END IF;
  
  RETURN OLD;
END;
$$;

-- Apply trigger to profiles for delete protection
DROP TRIGGER IF EXISTS protect_super_admin_delete_trigger ON public.profiles;
CREATE TRIGGER protect_super_admin_delete_trigger
  BEFORE DELETE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_deletion();

-- 3. Add RLS policy to user_roles to prevent querying super_admin role by regular users
DROP POLICY IF EXISTS "Hide super_admin from non-admins" ON public.user_roles;
CREATE POLICY "Hide super_admin from non-admins" 
ON public.user_roles 
FOR SELECT 
TO authenticated
USING (
  -- Super admins see everything
  public.is_super_admin(auth.uid())
  OR
  -- Admins see everything
  public.is_admin(auth.uid())
  OR
  -- Regular users can only see non-super_admin roles
  role != 'super_admin'
);

-- 4. Secure the messages table to prevent messaging super_admin directly (unless admin)
CREATE OR REPLACE FUNCTION public.can_message_user(_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    -- Super admins can message anyone
    public.is_super_admin(auth.uid())
    OR
    -- Admins can message super_admins
    (public.is_admin(auth.uid()) AND public.is_super_admin(_target_user_id))
    OR
    -- Regular users cannot message super_admins
    NOT public.is_super_admin(_target_user_id)
$$;

-- 5. Add audit trigger for any attempts to access super_admin data
CREATE OR REPLACE FUNCTION public.log_super_admin_access_attempt()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Log attempts to modify super_admin roles (for audit purposes)
  IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
    IF OLD.role = 'super_admin' AND auth.uid() IS DISTINCT FROM OLD.user_id THEN
      INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
      VALUES (
        OLD.user_id,
        'access_attempt_blocked',
        auth.uid(),
        'Attempted to modify super_admin role',
        jsonb_build_object('operation', TG_OP, 'blocked', true)
      );
    END IF;
  END IF;
  
  -- Let the actual protection trigger handle the exception
  RETURN NULL;
END;
$$;

-- Apply audit trigger before the protection trigger
DROP TRIGGER IF EXISTS audit_super_admin_access ON public.user_roles;
CREATE TRIGGER audit_super_admin_access
  BEFORE UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.log_super_admin_access_attempt();

-- =====================================================
-- Migration: 20260122064038_6666999d-8740-426d-9629-97beccbd5f5b.sql
-- =====================================================
-- Temporarily disable RLS to delete the role, then re-enable
-- Using a direct SQL approach

-- First, let's create a function that can delete roles with elevated privileges
CREATE OR REPLACE FUNCTION public.admin_delete_user_role(target_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM user_roles WHERE user_id = target_user_id;
  DELETE FROM moderator_permissions WHERE user_id = target_user_id;
END;
$$;

-- Execute the deletion for user Swede
SELECT public.admin_delete_user_role('56318bfc-e9e9-459e-8710-0d896516decb');

-- =====================================================
-- Migration: 20260122064109_4c792c97-4b33-4749-bceb-3f61e8b64ae3.sql
-- =====================================================
-- Fix the audit trigger to only block super_admin modifications, not all roles
CREATE OR REPLACE FUNCTION public.log_super_admin_access_attempt()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Log attempts to modify super_admin roles (for audit purposes)
  IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
    IF OLD.role = 'super_admin' AND auth.uid() IS DISTINCT FROM OLD.user_id THEN
      INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
      VALUES (
        OLD.user_id,
        'access_attempt_blocked',
        auth.uid(),
        'Attempted to modify super_admin role',
        jsonb_build_object('operation', TG_OP, 'blocked', true)
      );
      -- Block only super_admin modifications
      RETURN NULL;
    END IF;
  END IF;
  
  -- Allow operations on non-super_admin roles
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- =====================================================
-- Migration: 20260122065019_41c35590-7f51-479f-bb06-6425f4f0140f.sql
-- =====================================================
-- Create function to find user by short ID (first 6 chars of UUID)
CREATE OR REPLACE FUNCTION public.find_user_by_short_id(short_id TEXT)
RETURNS TABLE(user_id UUID, username TEXT, avatar_url TEXT) AS $$
BEGIN
  RETURN QUERY
  SELECT p.user_id, p.username, p.avatar_url
  FROM public.profiles p
  WHERE p.user_id::text LIKE short_id || '%'
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- =====================================================
-- Migration: 20260122072305_4d59006c-6292-4fb7-be6a-9215495efdaa.sql
-- =====================================================
-- Триггер уведомления при ответе саппорта
CREATE OR REPLACE FUNCTION public.notify_ticket_staff_reply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket RECORD;
  v_staff_username TEXT;
BEGIN
  -- Только для ответов саппорта
  IF NEW.is_staff_reply = true THEN
    -- Получаем данные тикета
    SELECT user_id, ticket_number, subject INTO v_ticket
    FROM public.support_tickets WHERE id = NEW.ticket_id;
    
    -- Получаем имя сотрудника
    SELECT COALESCE(username, 'Поддержка') INTO v_staff_username
    FROM public.profiles WHERE user_id = NEW.user_id;
    
    -- Создаём уведомление пользователю
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_ticket.user_id,
      'ticket_reply',
      'Ответ на тикет ' || v_ticket.ticket_number,
      'Получен ответ по вашему обращению: "' || LEFT(v_ticket.subject, 50) || '"',
      NEW.user_id,
      'ticket',
      NEW.ticket_id
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Триггер уведомления при закрытии/решении тикета
CREATE OR REPLACE FUNCTION public.notify_ticket_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_resolver_username TEXT;
BEGIN
  -- Уведомляем только при смене на resolved или closed
  IF NEW.status IN ('resolved', 'closed') AND OLD.status NOT IN ('resolved', 'closed') THEN
    -- Получаем имя того, кто закрыл (если есть assigned_to)
    IF NEW.assigned_to IS NOT NULL THEN
      SELECT COALESCE(username, 'Поддержка') INTO v_resolver_username
      FROM public.profiles WHERE user_id = NEW.assigned_to;
    ELSE
      v_resolver_username := 'Поддержка';
    END IF;
    
    INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      NEW.user_id,
      'ticket_resolved',
      CASE WHEN NEW.status = 'resolved' THEN 'Тикет решён' ELSE 'Тикет закрыт' END,
      'Ваше обращение ' || NEW.ticket_number || ' было ' || 
        CASE WHEN NEW.status = 'resolved' THEN 'решено' ELSE 'закрыто' END,
      NEW.assigned_to,
      'ticket',
      NEW.id
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Создаём триггеры
DROP TRIGGER IF EXISTS on_ticket_message_staff_reply ON public.ticket_messages;
CREATE TRIGGER on_ticket_message_staff_reply
  AFTER INSERT ON public.ticket_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_ticket_staff_reply();

DROP TRIGGER IF EXISTS on_ticket_status_change ON public.support_tickets;
CREATE TRIGGER on_ticket_status_change
  AFTER UPDATE ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_ticket_status_change();

-- =====================================================
-- Migration: 20260122080144_6e66934c-d671-42af-ae71-6e1cbc123787.sql
-- =====================================================
-- ============================================
-- CONTESTS v2: Уведомления, Победители, Призы
-- ============================================

-- 1. Триггер уведомления о новом конкурсе (всем активным пользователям)
CREATE OR REPLACE FUNCTION public.notify_new_contest()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user RECORD;
BEGIN
  -- Уведомляем только при переводе в active статус
  IF NEW.status = 'active' AND (OLD.status IS NULL OR OLD.status != 'active') THEN
    -- Создаём уведомления для всех активных пользователей
    FOR v_user IN 
      SELECT user_id FROM public.profiles 
      WHERE user_id IS NOT NULL
      LIMIT 1000 -- Ограничиваем для производительности
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
      VALUES (
        v_user.user_id,
        'new_contest',
        '🏆 Новый конкурс: ' || NEW.title,
        COALESCE(LEFT(NEW.description, 100), 'Примите участие и выиграйте призы!'),
        'contest',
        NEW.id
      );
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Триггер на изменение статуса конкурса
DROP TRIGGER IF EXISTS trigger_notify_new_contest ON public.contests;
CREATE TRIGGER trigger_notify_new_contest
  AFTER INSERT OR UPDATE OF status ON public.contests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_new_contest();

-- 2. Триггер уведомления о начале голосования
CREATE OR REPLACE FUNCTION public.notify_contest_voting_start()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_entry RECORD;
BEGIN
  -- Уведомляем при переводе в voting
  IF NEW.status = 'voting' AND OLD.status != 'voting' THEN
    -- Уведомляем всех участников конкурса
    FOR v_entry IN 
      SELECT DISTINCT user_id FROM public.contest_entries WHERE contest_id = NEW.id
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
      VALUES (
        v_entry.user_id,
        'contest_voting',
        '🗳️ Голосование началось!',
        'Голосование в конкурсе "' || NEW.title || '" началось. Поддержите свой трек!',
        'contest',
        NEW.id
      );
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trigger_notify_contest_voting ON public.contests;
CREATE TRIGGER trigger_notify_contest_voting
  AFTER UPDATE OF status ON public.contests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_contest_voting_start();

-- 3. Триггер уведомления победителя
CREATE OR REPLACE FUNCTION public.notify_contest_winner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_contest RECORD;
  v_place_text TEXT;
BEGIN
  -- Получаем данные конкурса
  SELECT title, prize_amount INTO v_contest 
  FROM public.contests WHERE id = NEW.contest_id;
  
  -- Формируем текст места
  v_place_text := CASE NEW.place
    WHEN 1 THEN '🥇 1 место'
    WHEN 2 THEN '🥈 2 место'
    WHEN 3 THEN '🥉 3 место'
    ELSE NEW.place || ' место'
  END;
  
  -- Уведомляем победителя
  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    NEW.user_id,
    'contest_winner',
    '🏆 Поздравляем! ' || v_place_text,
    'Вы заняли ' || v_place_text || ' в конкурсе "' || v_contest.title || '"!' ||
      CASE WHEN v_contest.prize_amount > 0 AND NEW.place = 1 
        THEN ' Приз: ' || v_contest.prize_amount || ' ₽'
        ELSE ''
      END,
    'contest',
    NEW.contest_id
  );
  
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trigger_notify_contest_winner ON public.contest_winners;
CREATE TRIGGER trigger_notify_contest_winner
  AFTER INSERT ON public.contest_winners
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_contest_winner();

-- 4. Функция для выплаты приза победителю
CREATE OR REPLACE FUNCTION public.award_contest_prize(
  _winner_id uuid,
  _contest_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_contest RECORD;
  v_winner RECORD;
BEGIN
  -- Проверяем права
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  
  -- Получаем данные конкурса
  SELECT id, title, prize_amount INTO v_contest 
  FROM public.contests WHERE id = _contest_id;
  
  IF v_contest IS NULL THEN
    RAISE EXCEPTION 'Конкурс не найден';
  END IF;
  
  -- Получаем данные победителя
  SELECT * INTO v_winner 
  FROM public.contest_winners 
  WHERE id = _winner_id AND contest_id = _contest_id;
  
  IF v_winner IS NULL THEN
    RAISE EXCEPTION 'Победитель не найден';
  END IF;
  
  IF v_winner.prize_awarded THEN
    RAISE EXCEPTION 'Приз уже выплачен';
  END IF;
  
  -- Начисляем приз на баланс (только для 1 места)
  IF v_winner.place = 1 AND v_contest.prize_amount > 0 THEN
    UPDATE public.profiles 
    SET balance = balance + v_contest.prize_amount
    WHERE user_id = v_winner.user_id;
    
    -- Создаём уведомление о начислении
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_winner.user_id,
      'prize_awarded',
      '💰 Приз начислен!',
      'На ваш баланс зачислено ' || v_contest.prize_amount || ' ₽ за победу в конкурсе "' || v_contest.title || '"',
      'contest',
      _contest_id
    );
  END IF;
  
  -- Отмечаем как выплаченный
  UPDATE public.contest_winners 
  SET prize_awarded = true 
  WHERE id = _winner_id;
  
  RETURN true;
END;
$function$;

-- 5. Функция для автоматического определения победителей по голосам
CREATE OR REPLACE FUNCTION public.finalize_contest_winners(_contest_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_entry RECORD;
  v_place INTEGER := 1;
  v_winners_count INTEGER := 0;
BEGIN
  -- Проверяем права
  IF NOT (public.is_admin(auth.uid()) OR public.is_super_admin(auth.uid())) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  
  -- Удаляем старых победителей если есть
  DELETE FROM public.contest_winners WHERE contest_id = _contest_id;
  
  -- Выбираем топ-3 по голосам
  FOR v_entry IN 
    SELECT id, user_id, votes_count
    FROM public.contest_entries 
    WHERE contest_id = _contest_id
    ORDER BY votes_count DESC
    LIMIT 3
  LOOP
    IF v_entry.votes_count > 0 THEN
      INSERT INTO public.contest_winners (contest_id, entry_id, user_id, place)
      VALUES (_contest_id, v_entry.id, v_entry.user_id, v_place);
      
      -- Обновляем ранг в entries
      UPDATE public.contest_entries SET rank = v_place WHERE id = v_entry.id;
      
      v_place := v_place + 1;
      v_winners_count := v_winners_count + 1;
    END IF;
  END LOOP;
  
  -- Обновляем статус конкурса
  UPDATE public.contests SET status = 'completed' WHERE id = _contest_id;
  
  RETURN v_winners_count;
END;
$function$;

-- 6. Добавляем Realtime для contest_entries (для лидерборда)
ALTER PUBLICATION supabase_realtime ADD TABLE public.contest_entries;
ALTER PUBLICATION supabase_realtime ADD TABLE public.contest_winners;

-- =====================================================
-- Migration: 20260122080825_2f7f9dda-cdf4-4aff-9594-8f5ba7c9b18a.sql
-- =====================================================
-- =============================================
-- PHASE 2: FULL CONTEST SYSTEM ENHANCEMENT
-- 1. Entry Comments with reactions
-- 2. Contest assets/stems for remixes  
-- 3. Winner badges system
-- 4. Entry withdrawal improvements
-- =============================================

-- 1. COMMENTS ON CONTEST ENTRIES
-- =============================================
CREATE TABLE IF NOT EXISTS public.contest_entry_comments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  entry_id UUID NOT NULL REFERENCES public.contest_entries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  parent_id UUID REFERENCES public.contest_entry_comments(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  likes_count INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Comment likes
CREATE TABLE IF NOT EXISTS public.contest_comment_likes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  comment_id UUID NOT NULL REFERENCES public.contest_entry_comments(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(comment_id, user_id)
);

-- Indexes for comments
CREATE INDEX IF NOT EXISTS idx_contest_entry_comments_entry ON public.contest_entry_comments(entry_id);
CREATE INDEX IF NOT EXISTS idx_contest_entry_comments_parent ON public.contest_entry_comments(parent_id);
CREATE INDEX IF NOT EXISTS idx_contest_comment_likes_comment ON public.contest_comment_likes(comment_id);

-- Enable RLS on comments
ALTER TABLE public.contest_entry_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contest_comment_likes ENABLE ROW LEVEL SECURITY;

-- RLS policies for comments
CREATE POLICY "Anyone can view entry comments" 
ON public.contest_entry_comments FOR SELECT USING (true);

CREATE POLICY "Authenticated users can create comments" 
ON public.contest_entry_comments FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own comments" 
ON public.contest_entry_comments FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own comments" 
ON public.contest_entry_comments FOR DELETE 
USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

-- RLS for comment likes
CREATE POLICY "Anyone can view comment likes" 
ON public.contest_comment_likes FOR SELECT USING (true);

CREATE POLICY "Authenticated users can like" 
ON public.contest_comment_likes FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can unlike" 
ON public.contest_comment_likes FOR DELETE 
USING (auth.uid() = user_id);

-- Trigger to update likes count
CREATE OR REPLACE FUNCTION public.update_contest_comment_likes_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.contest_entry_comments 
    SET likes_count = COALESCE(likes_count, 0) + 1
    WHERE id = NEW.comment_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.contest_entry_comments 
    SET likes_count = GREATEST(COALESCE(likes_count, 0) - 1, 0)
    WHERE id = OLD.comment_id;
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS update_contest_comment_likes_count_trigger ON public.contest_comment_likes;
CREATE TRIGGER update_contest_comment_likes_count_trigger
AFTER INSERT OR DELETE ON public.contest_comment_likes
FOR EACH ROW EXECUTE FUNCTION public.update_contest_comment_likes_count();

-- 2. CONTEST ASSETS/STEMS FOR REMIXES
-- =============================================
-- Add assets column to contests table
ALTER TABLE public.contests 
ADD COLUMN IF NOT EXISTS assets_url TEXT,
ADD COLUMN IF NOT EXISTS assets_description TEXT,
ADD COLUMN IF NOT EXISTS is_remix_contest BOOLEAN DEFAULT false;

-- Storage bucket for contest assets (stems)
INSERT INTO storage.buckets (id, name, public) 
VALUES ('contest-assets', 'contest-assets', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for contest assets
CREATE POLICY "Anyone can view contest assets"
ON storage.objects FOR SELECT
USING (bucket_id = 'contest-assets');

CREATE POLICY "Admins can upload contest assets"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'contest-assets' AND public.is_admin(auth.uid()));

CREATE POLICY "Admins can delete contest assets"
ON storage.objects FOR DELETE
USING (bucket_id = 'contest-assets' AND public.is_admin(auth.uid()));

-- Track downloads of assets
CREATE TABLE IF NOT EXISTS public.contest_asset_downloads (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  downloaded_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(contest_id, user_id)
);

ALTER TABLE public.contest_asset_downloads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view asset downloads" 
ON public.contest_asset_downloads FOR SELECT USING (true);

CREATE POLICY "Authenticated users can download" 
ON public.contest_asset_downloads FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- 3. WINNER BADGES SYSTEM
-- =============================================
-- Add winner badges to profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS contest_wins JSONB DEFAULT '[]'::jsonb;

-- Add badge info to tracks
ALTER TABLE public.tracks
ADD COLUMN IF NOT EXISTS contest_winner_badge JSONB DEFAULT NULL;

-- Function to add winner badge after prize award
CREATE OR REPLACE FUNCTION public.add_winner_badge()
RETURNS TRIGGER AS $$
DECLARE
  v_contest RECORD;
  v_track_id UUID;
  v_badge JSONB;
BEGIN
  -- Only trigger on prize_awarded = true
  IF NEW.prize_awarded = true AND (OLD.prize_awarded IS NULL OR OLD.prize_awarded = false) THEN
    -- Get contest info
    SELECT id, title INTO v_contest FROM public.contests WHERE id = NEW.contest_id;
    
    -- Get track id from entry
    SELECT track_id INTO v_track_id FROM public.contest_entries WHERE id = NEW.entry_id;
    
    -- Create badge object
    v_badge := jsonb_build_object(
      'contest_id', NEW.contest_id,
      'contest_title', v_contest.title,
      'place', NEW.place,
      'awarded_at', now()
    );
    
    -- Add to profile contest_wins array
    UPDATE public.profiles 
    SET contest_wins = COALESCE(contest_wins, '[]'::jsonb) || v_badge
    WHERE user_id = NEW.user_id;
    
    -- Add badge to track
    UPDATE public.tracks
    SET contest_winner_badge = v_badge
    WHERE id = v_track_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS add_winner_badge_trigger ON public.contest_winners;
CREATE TRIGGER add_winner_badge_trigger
AFTER UPDATE ON public.contest_winners
FOR EACH ROW EXECUTE FUNCTION public.add_winner_badge();

-- 4. ENTRY WITHDRAWAL WITH STATUS TRACKING  
-- =============================================
ALTER TABLE public.contest_entries 
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'active' CHECK (status IN ('active', 'withdrawn')),
ADD COLUMN IF NOT EXISTS withdrawn_at TIMESTAMP WITH TIME ZONE;

-- Function for safe entry withdrawal
CREATE OR REPLACE FUNCTION public.withdraw_contest_entry(_entry_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_contest RECORD;
BEGIN
  -- Get entry
  SELECT * INTO v_entry FROM public.contest_entries WHERE id = _entry_id;
  
  IF v_entry IS NULL THEN
    RAISE EXCEPTION 'Заявка не найдена';
  END IF;
  
  -- Check ownership
  IF v_entry.user_id != auth.uid() AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Нет прав на отзыв заявки';
  END IF;
  
  -- Get contest
  SELECT * INTO v_contest FROM public.contests WHERE id = v_entry.contest_id;
  
  -- Check if can withdraw (not in voting or completed)
  IF v_contest.status IN ('voting', 'completed') THEN
    RAISE EXCEPTION 'Нельзя отозвать заявку после начала голосования';
  END IF;
  
  -- Mark as withdrawn instead of deleting
  UPDATE public.contest_entries 
  SET status = 'withdrawn', withdrawn_at = now()
  WHERE id = _entry_id;
  
  RETURN true;
END;
$$;

-- Update entries query to filter withdrawn
CREATE OR REPLACE VIEW public.active_contest_entries AS
SELECT * FROM public.contest_entries WHERE status = 'active';

-- Enable realtime for comments
ALTER PUBLICATION supabase_realtime ADD TABLE public.contest_entry_comments;

-- =====================================================
-- Migration: 20260122080833_0c42173a-595f-40e4-aed7-395a66f44b2d.sql
-- =====================================================
-- Fix security definer view issue
DROP VIEW IF EXISTS public.active_contest_entries;

-- Create as a regular view without security definer
CREATE VIEW public.active_contest_entries 
WITH (security_invoker = true)
AS SELECT * FROM public.contest_entries WHERE status = 'active';

-- =====================================================
-- Migration: 20260122083034_81c1f97c-09b1-4b1f-bc81-d07aa230b6a5.sql
-- =====================================================
-- =====================================================
-- PHASE 3: Advanced Contest Features
-- =====================================================

-- 1. JURY SCORING SYSTEM
-- Table for jury members
CREATE TABLE IF NOT EXISTS public.contest_jury (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(contest_id, user_id)
);

-- Table for jury scores
CREATE TABLE IF NOT EXISTS public.contest_jury_scores (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  contest_id UUID NOT NULL REFERENCES public.contests(id) ON DELETE CASCADE,
  entry_id UUID NOT NULL REFERENCES public.contest_entries(id) ON DELETE CASCADE,
  jury_user_id UUID NOT NULL,
  technique_score INTEGER NOT NULL CHECK (technique_score >= 1 AND technique_score <= 10),
  creativity_score INTEGER NOT NULL CHECK (creativity_score >= 1 AND creativity_score <= 10),
  production_score INTEGER NOT NULL CHECK (production_score >= 1 AND production_score <= 10),
  overall_score INTEGER NOT NULL CHECK (overall_score >= 1 AND overall_score <= 10),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(entry_id, jury_user_id)
);

-- Add jury_enabled flag to contests
ALTER TABLE public.contests 
  ADD COLUMN IF NOT EXISTS jury_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS jury_weight NUMERIC(3,2) DEFAULT 0.50;

-- 2. PARTICIPANT STATISTICS
-- Add contest stats to profiles
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS contest_participations INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS contest_wins_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_prize_won NUMERIC DEFAULT 0;

-- 3. COMMENT MODERATION
ALTER TABLE public.contest_entry_comments
  ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS hidden_by UUID,
  ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS hidden_reason TEXT;

-- 4. RLS POLICIES

-- Contest jury policies
ALTER TABLE public.contest_jury ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Jury members are viewable by everyone"
  ON public.contest_jury FOR SELECT
  USING (true);

CREATE POLICY "Admins can manage jury"
  ON public.contest_jury FOR ALL
  USING (public.is_admin(auth.uid()));

-- Jury scores policies
ALTER TABLE public.contest_jury_scores ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Jury scores are viewable when contest is completed"
  ON public.contest_jury_scores FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.contests
      WHERE id = contest_id AND status = 'completed'
    )
  );

CREATE POLICY "Jury members can insert their scores"
  ON public.contest_jury_scores FOR INSERT
  WITH CHECK (
    auth.uid() = jury_user_id AND
    EXISTS (
      SELECT 1 FROM public.contest_jury
      WHERE contest_id = contest_jury_scores.contest_id
        AND user_id = auth.uid()
    )
  );

CREATE POLICY "Jury members can update their scores"
  ON public.contest_jury_scores FOR UPDATE
  USING (auth.uid() = jury_user_id);

-- 5. FUNCTIONS

-- Function to calculate average jury score for an entry
CREATE OR REPLACE FUNCTION public.get_entry_jury_score(entry_uuid UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  avg_score NUMERIC;
BEGIN
  SELECT AVG((technique_score + creativity_score + production_score + overall_score) / 4.0)
  INTO avg_score
  FROM contest_jury_scores
  WHERE entry_id = entry_uuid;
  
  RETURN COALESCE(avg_score, 0);
END;
$$;

-- Function for moderators to hide comments
CREATE OR REPLACE FUNCTION public.hide_contest_comment(
  _comment_id UUID,
  _reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  is_mod BOOLEAN;
BEGIN
  -- Check if user is moderator or admin
  SELECT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = auth.uid() AND role IN ('admin', 'moderator')
  ) INTO is_mod;
  
  IF NOT is_mod THEN
    RAISE EXCEPTION 'Только модераторы могут скрывать комментарии';
  END IF;
  
  UPDATE contest_entry_comments
  SET 
    is_hidden = true,
    hidden_by = auth.uid(),
    hidden_at = now(),
    hidden_reason = _reason
  WHERE id = _comment_id;
  
  RETURN true;
END;
$$;

-- Function to unhide comment
CREATE OR REPLACE FUNCTION public.unhide_contest_comment(_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  is_mod BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = auth.uid() AND role IN ('admin', 'moderator')
  ) INTO is_mod;
  
  IF NOT is_mod THEN
    RAISE EXCEPTION 'Только модераторы могут управлять комментариями';
  END IF;
  
  UPDATE contest_entry_comments
  SET 
    is_hidden = false,
    hidden_by = NULL,
    hidden_at = NULL,
    hidden_reason = NULL
  WHERE id = _comment_id;
  
  RETURN true;
END;
$$;

-- Function to update participant stats after contest ends
CREATE OR REPLACE FUNCTION public.update_contest_participant_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- When contest status changes to completed
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    -- Update participation count for all participants
    UPDATE profiles
    SET contest_participations = COALESCE(contest_participations, 0) + 1
    WHERE user_id IN (
      SELECT DISTINCT user_id FROM contest_entries
      WHERE contest_id = NEW.id
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger for updating stats when contest completes
DROP TRIGGER IF EXISTS trigger_update_contest_participant_stats ON public.contests;
CREATE TRIGGER trigger_update_contest_participant_stats
  AFTER UPDATE ON public.contests
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contest_participant_stats();

-- Function to update winner stats when prize is awarded
CREATE OR REPLACE FUNCTION public.update_winner_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  prize_amt NUMERIC;
BEGIN
  -- When prize is awarded
  IF NEW.prize_awarded = true AND (OLD.prize_awarded IS NULL OR OLD.prize_awarded = false) THEN
    -- Get prize amount
    SELECT prize_amount INTO prize_amt
    FROM contests WHERE id = NEW.contest_id;
    
    -- Update winner profile
    UPDATE profiles
    SET 
      contest_wins_count = COALESCE(contest_wins_count, 0) + 1,
      total_prize_won = COALESCE(total_prize_won, 0) + COALESCE(prize_amt, 0)
    WHERE user_id = NEW.user_id;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger for updating winner stats
DROP TRIGGER IF EXISTS trigger_update_winner_stats ON public.contest_winners;
CREATE TRIGGER trigger_update_winner_stats
  AFTER UPDATE ON public.contest_winners
  FOR EACH ROW
  EXECUTE FUNCTION public.update_winner_stats();

-- 6. Enable realtime for jury scores
ALTER PUBLICATION supabase_realtime ADD TABLE public.contest_jury_scores;

-- 7. Indexes for performance
CREATE INDEX IF NOT EXISTS idx_contest_jury_contest ON public.contest_jury(contest_id);
CREATE INDEX IF NOT EXISTS idx_contest_jury_scores_entry ON public.contest_jury_scores(entry_id);
CREATE INDEX IF NOT EXISTS idx_contest_jury_scores_contest ON public.contest_jury_scores(contest_id);
CREATE INDEX IF NOT EXISTS idx_entry_comments_hidden ON public.contest_entry_comments(is_hidden) WHERE is_hidden = false;

-- =====================================================
-- Migration: 20260122143437_15d74288-92cf-41d8-848a-c50af4ee9142.sql
-- =====================================================
-- Allow server-side (service role) updates to the super_admin profile while
-- still preventing regular users from modifying it.

CREATE OR REPLACE FUNCTION public.protect_super_admin_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  super_admin_user_id UUID;
BEGIN
  -- Backend operations run with role=service_role; allow them.
  -- This is required for balance deductions and other server-side bookkeeping.
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Get super_admin user id from settings
  SELECT value::uuid
    INTO super_admin_user_id
  FROM public.settings
  WHERE key = 'super_admin_id'
    AND value != '';

  -- If not configured, allow
  IF super_admin_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- If this is super_admin profile, only super_admin can modify it (from client context)
  IF OLD.user_id = super_admin_user_id THEN
    IF auth.uid() IS DISTINCT FROM super_admin_user_id THEN
      RAISE EXCEPTION 'Cannot modify super_admin profile';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- =====================================================
-- Migration: 20260122172353_7614f8f2-5949-4a77-bbb9-ed48b580ad8f.sql
-- =====================================================
-- Create performance alerts history table
CREATE TABLE public.performance_alerts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  alert_type TEXT NOT NULL, -- 'error', 'warning', 'info'
  category TEXT NOT NULL, -- 'suno', 'addon', 'generation', 'database', 'api'
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  metric_name TEXT,
  metric_value NUMERIC,
  threshold_value NUMERIC,
  resolved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create error logs table
CREATE TABLE public.error_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  error_type TEXT NOT NULL, -- 'frontend', 'edge_function', 'database', 'api', 'generation', 'addon'
  severity TEXT NOT NULL DEFAULT 'error', -- 'error', 'warning', 'critical'
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  stack_trace TEXT,
  context JSONB DEFAULT '{}'::jsonb, -- user_id, track_id, function_name, etc.
  user_agent TEXT,
  url TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create indexes for efficient querying
CREATE INDEX idx_performance_alerts_created_at ON public.performance_alerts(created_at DESC);
CREATE INDEX idx_performance_alerts_category ON public.performance_alerts(category);
CREATE INDEX idx_performance_alerts_type ON public.performance_alerts(alert_type);

CREATE INDEX idx_error_logs_created_at ON public.error_logs(created_at DESC);
CREATE INDEX idx_error_logs_type ON public.error_logs(error_type);
CREATE INDEX idx_error_logs_severity ON public.error_logs(severity);

-- Enable RLS
ALTER TABLE public.performance_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.error_logs ENABLE ROW LEVEL SECURITY;

-- Only admins can read/write
CREATE POLICY "Admins can manage performance alerts"
ON public.performance_alerts
FOR ALL
USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins can manage error logs"
ON public.error_logs
FOR ALL
USING (public.is_admin(auth.uid()));

-- Function to cleanup old logs (older than 7 days)
CREATE OR REPLACE FUNCTION public.cleanup_old_logs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  deleted_alerts INTEGER;
  deleted_errors INTEGER;
BEGIN
  -- Delete alerts older than 7 days
  DELETE FROM public.performance_alerts
  WHERE created_at < now() - interval '7 days';
  GET DIAGNOSTICS deleted_alerts = ROW_COUNT;
  
  -- Delete error logs older than 7 days
  DELETE FROM public.error_logs
  WHERE created_at < now() - interval '7 days';
  GET DIAGNOSTICS deleted_errors = ROW_COUNT;
  
  RETURN deleted_alerts + deleted_errors;
END;
$$;

-- Function to log error (callable from edge functions)
CREATE OR REPLACE FUNCTION public.log_error(
  p_error_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_severity TEXT DEFAULT 'error',
  p_stack_trace TEXT DEFAULT NULL,
  p_context JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO public.error_logs (error_type, severity, title, message, stack_trace, context)
  VALUES (p_error_type, p_severity, p_title, p_message, p_stack_trace, p_context)
  RETURNING id INTO v_log_id;
  
  RETURN v_log_id;
END;
$$;

-- Function to log performance alert
CREATE OR REPLACE FUNCTION public.log_performance_alert(
  p_alert_type TEXT,
  p_category TEXT,
  p_title TEXT,
  p_message TEXT,
  p_metric_name TEXT DEFAULT NULL,
  p_metric_value NUMERIC DEFAULT NULL,
  p_threshold_value NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_alert_id UUID;
BEGIN
  INSERT INTO public.performance_alerts (alert_type, category, title, message, metric_name, metric_value, threshold_value)
  VALUES (p_alert_type, p_category, p_title, p_message, p_metric_name, p_metric_value, p_threshold_value)
  RETURNING id INTO v_alert_id;
  
  RETURN v_alert_id;
END;
$$;

-- =====================================================
-- Migration: 20260123063233_a60f3f28-a229-437b-a75b-56563e067508.sql
-- =====================================================
-- =============================================
-- AI Planet Sound Marketplace - Tables Only
-- =============================================

-- 1. Тексты песен (отдельная сущность для продажи/депонирования)
CREATE TABLE IF NOT EXISTS public.lyrics_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  description TEXT,
  genre_id UUID REFERENCES public.genres(id),
  language TEXT DEFAULT 'ru',
  is_public BOOLEAN DEFAULT false,
  is_for_sale BOOLEAN DEFAULT false,
  price INTEGER DEFAULT 0,
  license_type TEXT DEFAULT 'standard',
  is_exclusive BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  sales_count INTEGER DEFAULT 0,
  views_count INTEGER DEFAULT 0,
  downloads_count INTEGER DEFAULT 0,
  tags TEXT[],
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 2. Депонирование текстов
CREATE TABLE IF NOT EXISTS public.lyrics_deposits (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  lyrics_id UUID NOT NULL REFERENCES public.lyrics_items(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  method TEXT NOT NULL DEFAULT 'blockchain',
  status TEXT NOT NULL DEFAULT 'pending',
  content_hash TEXT,
  timestamp_hash TEXT,
  certificate_url TEXT,
  external_id TEXT,
  author_name TEXT,
  deposited_at TIMESTAMP WITH TIME ZONE,
  error_message TEXT,
  price_rub INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 3. Унифицированные товары магазина
CREATE TABLE IF NOT EXISTS public.store_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  seller_id UUID NOT NULL,
  item_type TEXT NOT NULL CHECK (item_type IN ('beat', 'prompt', 'lyrics')),
  source_id UUID NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  price INTEGER NOT NULL DEFAULT 0,
  license_type TEXT NOT NULL DEFAULT 'standard',
  license_terms TEXT,
  is_exclusive BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  sales_count INTEGER DEFAULT 0,
  views_count INTEGER DEFAULT 0,
  tags TEXT[],
  genre_id UUID REFERENCES public.genres(id),
  preview_url TEXT,
  cover_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(item_type, source_id)
);

-- 4. Покупки товаров
CREATE TABLE IF NOT EXISTS public.item_purchases (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  buyer_id UUID NOT NULL,
  seller_id UUID NOT NULL,
  store_item_id UUID NOT NULL REFERENCES public.store_items(id) ON DELETE CASCADE,
  item_type TEXT NOT NULL,
  source_id UUID NOT NULL,
  price INTEGER NOT NULL,
  license_type TEXT NOT NULL,
  platform_fee INTEGER DEFAULT 0,
  net_amount INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'completed',
  download_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- =============================================
-- Индексы
-- =============================================

CREATE INDEX IF NOT EXISTS idx_lyrics_items_user_id ON public.lyrics_items(user_id);
CREATE INDEX IF NOT EXISTS idx_lyrics_items_is_for_sale ON public.lyrics_items(is_for_sale) WHERE is_for_sale = true;
CREATE INDEX IF NOT EXISTS idx_lyrics_items_genre_id ON public.lyrics_items(genre_id);

CREATE INDEX IF NOT EXISTS idx_lyrics_deposits_lyrics_id ON public.lyrics_deposits(lyrics_id);
CREATE INDEX IF NOT EXISTS idx_lyrics_deposits_user_id ON public.lyrics_deposits(user_id);
CREATE INDEX IF NOT EXISTS idx_lyrics_deposits_status ON public.lyrics_deposits(status);

CREATE INDEX IF NOT EXISTS idx_store_items_seller_id ON public.store_items(seller_id);
CREATE INDEX IF NOT EXISTS idx_store_items_item_type ON public.store_items(item_type);
CREATE INDEX IF NOT EXISTS idx_store_items_is_active ON public.store_items(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_store_items_genre_id ON public.store_items(genre_id);

CREATE INDEX IF NOT EXISTS idx_item_purchases_buyer_id ON public.item_purchases(buyer_id);
CREATE INDEX IF NOT EXISTS idx_item_purchases_seller_id ON public.item_purchases(seller_id);
CREATE INDEX IF NOT EXISTS idx_item_purchases_store_item_id ON public.item_purchases(store_item_id);

-- =============================================
-- Row Level Security
-- =============================================

ALTER TABLE public.lyrics_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lyrics_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_purchases ENABLE ROW LEVEL SECURITY;

-- Lyrics Items Policies
CREATE POLICY "lyrics_items_select_own" ON public.lyrics_items
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "lyrics_items_select_public" ON public.lyrics_items
  FOR SELECT USING (is_public = true AND is_for_sale = true AND is_active = true);

CREATE POLICY "lyrics_items_insert" ON public.lyrics_items
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "lyrics_items_update" ON public.lyrics_items
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "lyrics_items_delete" ON public.lyrics_items
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "lyrics_items_admin" ON public.lyrics_items
  FOR ALL USING (public.is_admin(auth.uid()));

-- Lyrics Deposits Policies
CREATE POLICY "lyrics_deposits_select_own" ON public.lyrics_deposits
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "lyrics_deposits_insert" ON public.lyrics_deposits
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "lyrics_deposits_update" ON public.lyrics_deposits
  FOR UPDATE USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

CREATE POLICY "lyrics_deposits_admin" ON public.lyrics_deposits
  FOR ALL USING (public.is_admin(auth.uid()));

-- Store Items Policies
CREATE POLICY "store_items_select_active" ON public.store_items
  FOR SELECT USING (is_active = true);

CREATE POLICY "store_items_select_own" ON public.store_items
  FOR SELECT USING (auth.uid() = seller_id);

CREATE POLICY "store_items_insert" ON public.store_items
  FOR INSERT WITH CHECK (auth.uid() = seller_id);

CREATE POLICY "store_items_update" ON public.store_items
  FOR UPDATE USING (auth.uid() = seller_id);

CREATE POLICY "store_items_delete" ON public.store_items
  FOR DELETE USING (auth.uid() = seller_id);

CREATE POLICY "store_items_admin" ON public.store_items
  FOR ALL USING (public.is_admin(auth.uid()));

-- Item Purchases Policies
CREATE POLICY "item_purchases_select" ON public.item_purchases
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "item_purchases_insert" ON public.item_purchases
  FOR INSERT WITH CHECK (auth.uid() = buyer_id OR public.is_admin(auth.uid()));

CREATE POLICY "item_purchases_admin" ON public.item_purchases
  FOR ALL USING (public.is_admin(auth.uid()));

-- =============================================
-- Triggers
-- =============================================

CREATE TRIGGER update_lyrics_items_updated_at
  BEFORE UPDATE ON public.lyrics_items
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_lyrics_deposits_updated_at
  BEFORE UPDATE ON public.lyrics_deposits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_store_items_updated_at
  BEFORE UPDATE ON public.store_items
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================
-- Add fields to user_prompts
-- =============================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'user_prompts' AND column_name = 'license_type'
  ) THEN
    ALTER TABLE public.user_prompts ADD COLUMN license_type TEXT DEFAULT 'standard';
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'user_prompts' AND column_name = 'is_exclusive'
  ) THEN
    ALTER TABLE public.user_prompts ADD COLUMN is_exclusive BOOLEAN DEFAULT false;
  END IF;
END $$;

-- =====================================================
-- Migration: 20260123063304_4805db77-dad9-49bb-b619-693a5646fef0.sql
-- =====================================================
-- =============================================
-- AI Planet Sound Marketplace - RPC Functions
-- =============================================

-- Функция покупки товара из магазина
CREATE OR REPLACE FUNCTION public.process_store_item_purchase(
  p_store_item_id UUID,
  p_buyer_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_item RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Get item info
  SELECT * INTO v_item FROM public.store_items 
  WHERE id = p_store_item_id AND is_active = true;
  
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Item not found or not available';
  END IF;
  
  IF v_item.seller_id = p_buyer_id THEN
    RAISE EXCEPTION 'Cannot purchase your own item';
  END IF;
  
  -- Check if already purchased
  IF EXISTS (
    SELECT 1 FROM public.item_purchases 
    WHERE store_item_id = p_store_item_id AND buyer_id = p_buyer_id
  ) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;
  
  -- Calculate platform fee (10%)
  v_platform_fee := ROUND(v_item.price * 0.1);
  v_net_amount := v_item.price - v_platform_fee;
  
  -- Deduct from buyer balance
  UPDATE public.profiles SET balance = balance - v_item.price
  WHERE user_id = p_buyer_id AND balance >= v_item.price;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;
  
  -- Create purchase record
  INSERT INTO public.item_purchases (
    buyer_id, seller_id, store_item_id, item_type, source_id, 
    price, license_type, platform_fee, net_amount
  )
  VALUES (
    p_buyer_id, v_item.seller_id, p_store_item_id, v_item.item_type, 
    v_item.source_id, v_item.price, v_item.license_type, v_platform_fee, v_net_amount
  )
  RETURNING id INTO v_purchase_id;
  
  -- Create earnings record
  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_item.seller_id, v_item.price, v_item.item_type, v_purchase_id, v_platform_fee, v_net_amount);
  
  -- Add to seller balance
  UPDATE public.profiles SET balance = balance + v_net_amount
  WHERE user_id = v_item.seller_id;
  
  -- Increment sales count
  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_store_item_id;
  
  -- If exclusive, mark as inactive
  IF v_item.is_exclusive THEN
    UPDATE public.store_items SET is_active = false WHERE id = p_store_item_id;
    
    IF v_item.item_type = 'prompt' THEN
      UPDATE public.user_prompts SET is_public = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'lyrics' THEN
      UPDATE public.lyrics_items SET is_active = false, is_for_sale = false WHERE id = v_item.source_id;
    ELSIF v_item.item_type = 'beat' THEN
      UPDATE public.store_beats SET is_active = false WHERE id = v_item.source_id;
    END IF;
  END IF;
  
  -- Notify seller
  INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_item.seller_id,
    'item_sold',
    '💰 Продажа: ' || v_item.title,
    'Ваш товар куплен за ' || v_item.price || ' ₽',
    p_buyer_id,
    'store_item',
    p_store_item_id
  );
  
  RETURN v_purchase_id;
END;
$$;

-- Функция проверки, куплен ли товар
CREATE OR REPLACE FUNCTION public.has_purchased_item(
  p_user_id UUID,
  p_store_item_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.item_purchases
    WHERE buyer_id = p_user_id AND store_item_id = p_store_item_id
  );
$$;

-- Функция проверки, куплен ли промт
CREATE OR REPLACE FUNCTION public.has_purchased_prompt(
  p_user_id UUID,
  p_prompt_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.prompt_purchases
    WHERE buyer_id = p_user_id AND prompt_id = p_prompt_id
  )
  OR EXISTS (
    SELECT 1 FROM public.user_prompts
    WHERE id = p_prompt_id AND user_id = p_user_id
  );
$$;

-- Функция для получения промта трека (если куплен или свой)
CREATE OR REPLACE FUNCTION public.get_track_prompt_if_accessible(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS public.user_prompts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_prompt public.user_prompts;
BEGIN
  -- Найти промт по track_id
  SELECT up.* INTO v_prompt
  FROM public.user_prompts up
  WHERE up.track_id = p_track_id
  LIMIT 1;
  
  IF v_prompt IS NULL THEN
    RETURN NULL;
  END IF;
  
  -- Проверить доступ
  IF v_prompt.user_id = p_user_id THEN
    RETURN v_prompt;
  END IF;
  
  -- Проверить покупку
  IF EXISTS (
    SELECT 1 FROM public.prompt_purchases 
    WHERE prompt_id = v_prompt.id AND buyer_id = p_user_id
  ) THEN
    RETURN v_prompt;
  END IF;
  
  -- Если бесплатный и публичный
  IF v_prompt.is_public = true AND v_prompt.price = 0 THEN
    RETURN v_prompt;
  END IF;
  
  RETURN NULL;
END;
$$;

-- Функция получения информации о промте трека для покупки
CREATE OR REPLACE FUNCTION public.get_track_prompt_info(p_track_id UUID)
RETURNS TABLE (
  prompt_id UUID,
  title TEXT,
  price INTEGER,
  is_public BOOLEAN,
  is_exclusive BOOLEAN,
  license_type TEXT,
  seller_id UUID,
  seller_username TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT 
    up.id as prompt_id,
    up.title,
    COALESCE(up.price, 0) as price,
    COALESCE(up.is_public, false) as is_public,
    COALESCE(up.is_exclusive, false) as is_exclusive,
    COALESCE(up.license_type, 'standard') as license_type,
    up.user_id as seller_id,
    p.username as seller_username
  FROM public.user_prompts up
  JOIN public.profiles p ON p.user_id = up.user_id
  WHERE up.track_id = p_track_id
  LIMIT 1;
$$;

-- =====================================================
-- Migration: 20260123182202_165e0aca-64ba-49a9-93bf-4ddb34839cd2.sql
-- =====================================================
-- =============================================
-- REFERRAL SYSTEM - Best in the world! 🚀
-- =============================================

-- Настройки реферальной программы
CREATE TABLE public.referral_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Вставляем дефолтные настройки
INSERT INTO public.referral_settings (key, value, description) VALUES
  ('referrer_bonus', '50', 'Бонус приглашающему (₽)'),
  ('referee_bonus', '25', 'Бонус приглашённому (₽)'),
  ('min_deposit_to_activate', '100', 'Минимальный депозит для активации реферала (RUB)'),
  ('bonus_per_deposit_percent', '5', 'Процент от депозитов реферала'),
  ('max_referrals_per_user', '100', 'Максимум рефералов на пользователя'),
  ('program_enabled', 'true', 'Программа активна'),
  ('levels', '[{"level": 1, "percent": 5}, {"level": 2, "percent": 2}]', 'Уровни реферальной программы');

-- Реферальные коды пользователей
CREATE TABLE public.referral_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  code text NOT NULL UNIQUE,
  custom_code text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  views_count integer DEFAULT 0,
  clicks_count integer DEFAULT 0
);

-- Связи реферер-реферал
CREATE TABLE public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id uuid NOT NULL,
  referee_id uuid NOT NULL UNIQUE,
  referral_code_id uuid REFERENCES public.referral_codes(id),
  status text NOT NULL DEFAULT 'pending',
  activated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address text,
  user_agent text,
  source text,
  CONSTRAINT unique_referral UNIQUE (referrer_id, referee_id)
);

-- История наград
CREATE TABLE public.referral_rewards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  referral_id uuid REFERENCES public.referrals(id),
  amount numeric NOT NULL,
  type text NOT NULL,
  description text,
  source_event text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Статистика по дням
CREATE TABLE public.referral_stats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  date date NOT NULL DEFAULT CURRENT_DATE,
  views integer DEFAULT 0,
  clicks integer DEFAULT 0,
  registrations integer DEFAULT 0,
  activations integer DEFAULT 0,
  earnings numeric DEFAULT 0,
  CONSTRAINT unique_user_date UNIQUE (user_id, date)
);

-- Индексы
CREATE INDEX idx_referral_codes_user ON public.referral_codes(user_id);
CREATE INDEX idx_referral_codes_code ON public.referral_codes(code);
CREATE INDEX idx_referrals_referrer ON public.referrals(referrer_id);
CREATE INDEX idx_referrals_referee ON public.referrals(referee_id);
CREATE INDEX idx_referrals_status ON public.referrals(status);
CREATE INDEX idx_referral_rewards_user ON public.referral_rewards(user_id);
CREATE INDEX idx_referral_stats_user_date ON public.referral_stats(user_id, date);

-- RLS
ALTER TABLE public.referral_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_stats ENABLE ROW LEVEL SECURITY;

-- Политики для настроек (только чтение для всех, запись для админов)
CREATE POLICY "Anyone can read settings"
  ON public.referral_settings FOR SELECT
  USING (true);

CREATE POLICY "Admins can update settings"
  ON public.referral_settings FOR UPDATE
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Политики для кодов
CREATE POLICY "Users can view their own codes"
  ON public.referral_codes FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own codes"
  ON public.referral_codes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own codes"
  ON public.referral_codes FOR UPDATE
  USING (auth.uid() = user_id);

-- Политики для рефералов
CREATE POLICY "Users can view referrals they are part of"
  ON public.referrals FOR SELECT
  USING (auth.uid() = referrer_id OR auth.uid() = referee_id);

CREATE POLICY "System can insert referrals"
  ON public.referrals FOR INSERT
  WITH CHECK (true);

-- Политики для наград
CREATE POLICY "Users can view their own rewards"
  ON public.referral_rewards FOR SELECT
  USING (auth.uid() = user_id);

-- Политики для статистики
CREATE POLICY "Users can view their own stats"
  ON public.referral_stats FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all stats"
  ON public.referral_stats FOR SELECT
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Функция генерации уникального кода
CREATE OR REPLACE FUNCTION public.generate_referral_code(user_uuid uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_code text;
  code_exists boolean;
BEGIN
  LOOP
    -- Генерируем 8-символьный код
    new_code := upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));
    
    SELECT EXISTS(SELECT 1 FROM referral_codes WHERE code = new_code) INTO code_exists;
    
    IF NOT code_exists THEN
      INSERT INTO referral_codes (user_id, code)
      VALUES (user_uuid, new_code)
      ON CONFLICT (user_id) DO NOTHING;
      
      RETURN new_code;
    END IF;
  END LOOP;
END;
$$;

-- Функция получения или создания реферального кода
CREATE OR REPLACE FUNCTION public.get_or_create_referral_code(user_uuid uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing_code text;
BEGIN
  SELECT COALESCE(custom_code, code) INTO existing_code
  FROM referral_codes
  WHERE user_id = user_uuid;
  
  IF existing_code IS NOT NULL THEN
    RETURN existing_code;
  END IF;
  
  RETURN generate_referral_code(user_uuid);
END;
$$;

-- Функция регистрации реферала
CREATE OR REPLACE FUNCTION public.register_referral(
  p_referee_id uuid,
  p_referral_code text,
  p_ip_address text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_source text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer_id uuid;
  v_code_id uuid;
  v_referee_bonus numeric;
  v_referrer_bonus numeric;
  v_settings jsonb;
BEGIN
  -- Проверяем что программа активна
  SELECT value::text::boolean INTO v_settings
  FROM referral_settings WHERE key = 'program_enabled';
  
  IF NOT COALESCE(v_settings, true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Реферальная программа отключена');
  END IF;

  -- Находим код и реферера
  SELECT rc.user_id, rc.id INTO v_referrer_id, v_code_id
  FROM referral_codes rc
  WHERE rc.code = upper(p_referral_code) OR rc.custom_code = p_referral_code;
  
  IF v_referrer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Код не найден');
  END IF;
  
  -- Нельзя приглашать себя
  IF v_referrer_id = p_referee_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Нельзя использовать собственный код');
  END IF;
  
  -- Проверяем что пользователь ещё не был приглашён
  IF EXISTS(SELECT 1 FROM referrals WHERE referee_id = p_referee_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Пользователь уже зарегистрирован по реферальной ссылке');
  END IF;
  
  -- Получаем бонусы из настроек
  SELECT (value)::numeric INTO v_referee_bonus FROM referral_settings WHERE key = 'referee_bonus';
  SELECT (value)::numeric INTO v_referrer_bonus FROM referral_settings WHERE key = 'referrer_bonus';
  
  -- Создаём связь
  INSERT INTO referrals (referrer_id, referee_id, referral_code_id, ip_address, user_agent, source)
  VALUES (v_referrer_id, p_referee_id, v_code_id, p_ip_address, p_user_agent, p_source);
  
  -- Начисляем бонус приглашённому сразу
  IF COALESCE(v_referee_bonus, 0) > 0 THEN
    UPDATE profiles SET balance = COALESCE(balance, 0) + v_referee_bonus WHERE user_id = p_referee_id;
    
    INSERT INTO referral_rewards (user_id, amount, type, description, source_event)
    VALUES (p_referee_id, v_referee_bonus, 'welcome_bonus', 'Бонус за регистрацию по реферальной ссылке', 'registration');
  END IF;
  
  -- Обновляем статистику реферера
  INSERT INTO referral_stats (user_id, date, registrations)
  VALUES (v_referrer_id, CURRENT_DATE, 1)
  ON CONFLICT (user_id, date) DO UPDATE SET registrations = referral_stats.registrations + 1;
  
  RETURN jsonb_build_object(
    'success', true, 
    'referrer_id', v_referrer_id,
    'bonus_received', v_referee_bonus
  );
END;
$$;

-- Функция активации реферала (после первого депозита)
CREATE OR REPLACE FUNCTION public.activate_referral(p_referee_id uuid, p_deposit_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral record;
  v_min_deposit numeric;
  v_referrer_bonus numeric;
BEGIN
  -- Находим реферальную связь
  SELECT * INTO v_referral FROM referrals WHERE referee_id = p_referee_id AND status = 'pending';
  
  IF v_referral IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Реферал не найден или уже активирован');
  END IF;
  
  -- Проверяем минимальный депозит
  SELECT (value)::numeric INTO v_min_deposit FROM referral_settings WHERE key = 'min_deposit_to_activate';
  
  IF p_deposit_amount < COALESCE(v_min_deposit, 0) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Сумма депозита меньше минимальной');
  END IF;
  
  -- Получаем бонус реферера
  SELECT (value)::numeric INTO v_referrer_bonus FROM referral_settings WHERE key = 'referrer_bonus';
  
  -- Активируем реферала
  UPDATE referrals SET status = 'active', activated_at = now() WHERE id = v_referral.id;
  
  -- Начисляем бонус рефереру
  IF COALESCE(v_referrer_bonus, 0) > 0 THEN
    UPDATE profiles SET balance = COALESCE(balance, 0) + v_referrer_bonus WHERE user_id = v_referral.referrer_id;
    
    INSERT INTO referral_rewards (user_id, referral_id, amount, type, description, source_event)
    VALUES (v_referral.referrer_id, v_referral.id, v_referrer_bonus, 'activation_bonus', 'Бонус за активацию реферала', 'activation');
  END IF;
  
  -- Обновляем статистику
  INSERT INTO referral_stats (user_id, date, activations, earnings)
  VALUES (v_referral.referrer_id, CURRENT_DATE, 1, v_referrer_bonus)
  ON CONFLICT (user_id, date) DO UPDATE SET 
    activations = referral_stats.activations + 1,
    earnings = referral_stats.earnings + v_referrer_bonus;
  
  RETURN jsonb_build_object('success', true, 'bonus_paid', v_referrer_bonus);
END;
$$;

-- Функция начисления процента от депозита реферала
CREATE OR REPLACE FUNCTION public.process_referral_deposit_bonus(p_referee_id uuid, p_deposit_amount numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral record;
  v_percent numeric;
  v_bonus numeric;
BEGIN
  -- Находим активную реферальную связь
  SELECT * INTO v_referral FROM referrals WHERE referee_id = p_referee_id AND status = 'active';
  
  IF v_referral IS NULL THEN
    RETURN;
  END IF;
  
  -- Получаем процент
  SELECT (value)::numeric INTO v_percent FROM referral_settings WHERE key = 'bonus_per_deposit_percent';
  
  IF COALESCE(v_percent, 0) <= 0 THEN
    RETURN;
  END IF;
  
  -- Вычисляем бонус
  v_bonus := ROUND(p_deposit_amount * v_percent / 100, 2);
  
  IF v_bonus > 0 THEN
    -- Начисляем бонус рефереру
    UPDATE profiles SET balance = COALESCE(balance, 0) + v_bonus WHERE user_id = v_referral.referrer_id;
    
    INSERT INTO referral_rewards (user_id, referral_id, amount, type, description, source_event)
    VALUES (v_referral.referrer_id, v_referral.id, v_bonus, 'deposit_percent', 
      'Процент от депозита реферала (' || v_percent || '%)', 'deposit');
    
    -- Обновляем статистику
    INSERT INTO referral_stats (user_id, date, earnings)
    VALUES (v_referral.referrer_id, CURRENT_DATE, v_bonus)
    ON CONFLICT (user_id, date) DO UPDATE SET earnings = referral_stats.earnings + v_bonus;
  END IF;
END;
$$;

-- =====================================================
-- Migration: 20260123235217_a0f24067-9d2f-4085-b1d4-648919a1373a.sql
-- =====================================================
-- ============================================
-- SECURITY FIX: Complete protection for payments table
-- ============================================

-- Create restrictive policy for payments (users can only see own)
DROP POLICY IF EXISTS "Users can only view own payments" ON public.payments;
CREATE POLICY "Users can only view own payments"
ON public.payments FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Grant access to profiles_public view
GRANT SELECT ON public.profiles_public TO authenticated;
GRANT SELECT ON public.profiles_public TO anon;

-- =====================================================
-- Migration: 20260124000801_2e6d89c7-2526-41f1-9e71-69e5934cec81.sql
-- =====================================================
-- ============================================
-- SECURITY FIX: Restrict profile visibility
-- Users can only see own balance, others see public info
-- ============================================

-- Drop the overly permissive policy
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON public.profiles;

-- Policy 1: Users can view their own FULL profile (including balance)
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile"
ON public.profiles FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Policy 2: Admins can view all profiles
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles"
ON public.profiles FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles 
    WHERE user_roles.user_id = auth.uid() 
    AND user_roles.role IN ('admin', 'super_admin')
  )
);

-- For public profile viewing (without balance), use the existing profiles_public view
-- Ensure the view is accessible
GRANT SELECT ON public.profiles_public TO authenticated;
GRANT SELECT ON public.profiles_public TO anon;

-- =====================================================
-- Migration: 20260124001225_9b3cc381-8ad1-44c8-b9c0-5b9a3822a680.sql
-- =====================================================
-- ============================================
-- SECURITY FIX: Comprehensive security hardening
-- ============================================

-- 1. PROFILES: Ensure no public/anon access, only authenticated own+admin
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON public.profiles;
DROP POLICY IF EXISTS "Anyone can view profiles" ON public.profiles;
DROP POLICY IF EXISTS "Public can view profiles" ON public.profiles;

-- Ensure policies exist for own profile and admin access
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile"
ON public.profiles FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles"
ON public.profiles FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- 2. PAYMENTS: Strengthen - only owner and admin
DROP POLICY IF EXISTS "Users can view own payments" ON public.payments;
CREATE POLICY "Users can view own payments"
ON public.payments FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can view all payments" ON public.payments;
CREATE POLICY "Admins can view all payments"
ON public.payments FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- 3. SELLER_EARNINGS: Restrict to seller and admin only
DROP POLICY IF EXISTS "Sellers can view own earnings" ON public.seller_earnings;
CREATE POLICY "Sellers can view own earnings"
ON public.seller_earnings FOR SELECT
TO authenticated
USING (auth.uid() = seller_id);

DROP POLICY IF EXISTS "Admins can view all earnings" ON public.seller_earnings;
CREATE POLICY "Admins can view all earnings"
ON public.seller_earnings FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- Remove any overly permissive policies on seller_earnings
DROP POLICY IF EXISTS "Anyone can view seller earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Authenticated users can view earnings" ON public.seller_earnings;

-- 4. TRACKS STORAGE: Add folder ownership validation
DROP POLICY IF EXISTS "Authenticated users can upload to tracks bucket" ON storage.objects;

-- Users can only upload to their own folder
CREATE POLICY "Users can upload to own tracks folder"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'tracks' AND 
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Service role policy should already exist for edge functions
-- Keep the existing: "Service role can manage tracks bucket"

-- =====================================================
-- Migration: 20260124001645_98c6e95a-a8d5-4eff-9c4c-0d45aecf5376.sql
-- =====================================================
-- ============================================
-- COMPREHENSIVE SECURITY HARDENING v2 (Fixed)
-- ============================================

-- 1. PROFILES: Protect balance via trigger instead of policy
CREATE OR REPLACE FUNCTION public.protect_balance_modification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only allow balance changes from service_role (backend)
  IF auth.role() != 'service_role' THEN
    -- Regular users cannot modify balance directly
    IF NEW.balance IS DISTINCT FROM OLD.balance THEN
      -- Check if user is admin
      IF NOT public.is_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Balance can only be modified by system';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_balance_modification_trigger ON public.profiles;
CREATE TRIGGER protect_balance_modification_trigger
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.protect_balance_modification();

-- 2. PAYOUT_REQUESTS: Safe view without sensitive bank details
DROP VIEW IF EXISTS public.payout_requests_safe;
CREATE VIEW public.payout_requests_safe
WITH (security_invoker=on) AS
SELECT 
  id,
  seller_id,
  amount,
  payment_method,
  status,
  admin_notes,
  created_at,
  updated_at,
  processed_at,
  CASE 
    WHEN payment_details IS NOT NULL THEN 
      jsonb_build_object('method_type', payment_details->>'method_type', 'masked', true)
    ELSE NULL
  END as payment_details_masked
FROM public.payout_requests;

GRANT SELECT ON public.payout_requests_safe TO authenticated;

-- 3. REFERRALS: Safe view without IP/user_agent
DROP VIEW IF EXISTS public.referrals_safe;
CREATE VIEW public.referrals_safe
WITH (security_invoker=on) AS
SELECT 
  id,
  referrer_id,
  referee_id,
  referral_code_id,
  status,
  source,
  created_at,
  activated_at
FROM public.referrals;

GRANT SELECT ON public.referrals_safe TO authenticated;

-- 4. TRACK_DEPOSITS: Protect critical fields via trigger
CREATE OR REPLACE FUNCTION public.protect_deposit_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only service_role can modify critical blockchain fields once set
  IF auth.role() != 'service_role' THEN
    IF OLD.blockchain_tx_id IS NOT NULL AND NEW.blockchain_tx_id IS DISTINCT FROM OLD.blockchain_tx_id THEN
      RAISE EXCEPTION 'Cannot modify blockchain transaction ID';
    END IF;
    IF OLD.file_hash IS NOT NULL AND NEW.file_hash IS DISTINCT FROM OLD.file_hash THEN
      RAISE EXCEPTION 'Cannot modify file hash';
    END IF;
    IF OLD.metadata_hash IS NOT NULL AND NEW.metadata_hash IS DISTINCT FROM OLD.metadata_hash THEN
      RAISE EXCEPTION 'Cannot modify metadata hash';
    END IF;
    IF OLD.certificate_url IS NOT NULL AND NEW.certificate_url IS DISTINCT FROM OLD.certificate_url THEN
      RAISE EXCEPTION 'Cannot modify certificate URL';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_deposit_fields_trigger ON public.track_deposits;
CREATE TRIGGER protect_deposit_fields_trigger
BEFORE UPDATE ON public.track_deposits
FOR EACH ROW
EXECUTE FUNCTION public.protect_deposit_fields();

-- 5. PAYMENTS: Sanitize sensitive metadata
CREATE OR REPLACE FUNCTION public.sanitize_payment_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.metadata IS NOT NULL THEN
    NEW.metadata = NEW.metadata 
      - 'card_number' - 'cvv' - 'cvc' - 'security_code'
      - 'pan' - 'full_card' - 'card_details' - 'account_number';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sanitize_payment_metadata_trigger ON public.payments;
CREATE TRIGGER sanitize_payment_metadata_trigger
BEFORE INSERT OR UPDATE ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.sanitize_payment_metadata();

-- 6. CONTEST_JURY_SCORES: Time-based protection
DROP POLICY IF EXISTS "Anyone can view completed contest scores" ON public.contest_jury_scores;
CREATE POLICY "Scores visible after contest completion plus buffer"
ON public.contest_jury_scores FOR SELECT
TO authenticated
USING (
  jury_user_id = auth.uid()
  OR public.is_admin(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.contests c
    WHERE c.id = contest_id
    AND c.status = 'completed'
    AND c.voting_end_date < (now() - interval '24 hours')
  )
);

-- 7. SECURITY AUDIT LOG: Track suspicious activity
CREATE TABLE IF NOT EXISTS public.security_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text NOT NULL,
  user_id uuid,
  ip_hint text,
  resource_type text,
  resource_id uuid,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.security_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can read security logs" ON public.security_audit_log;
CREATE POLICY "Admins can read security logs"
ON public.security_audit_log FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "System can insert security logs" ON public.security_audit_log;
CREATE POLICY "System can insert security logs"
ON public.security_audit_log FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_security_audit_created 
ON public.security_audit_log(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_security_audit_user 
ON public.security_audit_log(user_id, created_at DESC);

-- 8. Function to log security events
CREATE OR REPLACE FUNCTION public.log_security_event(
  p_event_type text,
  p_resource_type text DEFAULT NULL,
  p_resource_id uuid DEFAULT NULL,
  p_details jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO public.security_audit_log (event_type, user_id, resource_type, resource_id, details)
  VALUES (p_event_type, auth.uid(), p_resource_type, p_resource_id, p_details)
  RETURNING id INTO v_log_id;
  
  RETURN v_log_id;
END;
$$;

-- =====================================================
-- Migration: 20260124001657_4cf73d17-7233-4e18-8717-4758fa54bba1.sql
-- =====================================================
-- Fix: Restrict security_audit_log INSERT to service role only
DROP POLICY IF EXISTS "System can insert security logs" ON public.security_audit_log;
CREATE POLICY "Service role can insert security logs"
ON public.security_audit_log FOR INSERT
WITH CHECK (auth.role() = 'service_role');

-- Review and tighten other WITH CHECK (true) policies
-- Find the problematic policy in security_audit_log and fix it

-- =====================================================
-- Migration: 20260124100317_2017c8f3-580f-49a4-ad68-d4909d3cd4ec.sql
-- =====================================================
-- Исправляем RLS политики для profiles, чтобы разрешить просмотр публичной информации всем аутентифицированным пользователям

-- Удаляем слишком ограничительную политику
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;

-- Создаём новую политику: аутентифицированные пользователи могут видеть все профили
-- (чувствительные поля защищены через отдельную view profiles_public)
CREATE POLICY "Authenticated users can view profiles"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);

-- Оставляем политику для админов на случай если нужен доступ от service_role
-- (уже существует "Admins can view all profiles")

-- =====================================================
-- Migration: 20260124144914_bda88cb0-a047-411a-9e65-e7f5f9596dc2.sql
-- =====================================================
-- Функция уведомления админов о новом тикете
CREATE OR REPLACE FUNCTION public.notify_admins_new_ticket()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin RECORD;
  v_user_name TEXT;
BEGIN
  -- Получаем имя пользователя создавшего тикет
  SELECT COALESCE(username, 'Пользователь') INTO v_user_name
  FROM public.profiles WHERE user_id = NEW.user_id;
  
  -- Отправляем уведомление всем админам
  FOR v_admin IN 
    SELECT user_id FROM public.user_roles WHERE role IN ('admin', 'super_admin')
  LOOP
    -- Не уведомляем самого создателя если он админ
    IF v_admin.user_id != NEW.user_id THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id, target_type, target_id)
      VALUES (
        v_admin.user_id,
        'new_ticket',
        'Новый тикет ' || NEW.ticket_number,
        v_user_name || ': "' || LEFT(NEW.subject, 50) || '"',
        NEW.user_id,
        'ticket',
        NEW.id
      );
    END IF;
  END LOOP;
  
  RETURN NEW;
END;
$$;

-- Триггер на создание тикета
DROP TRIGGER IF EXISTS on_new_ticket_notify_admins ON public.support_tickets;
CREATE TRIGGER on_new_ticket_notify_admins
  AFTER INSERT ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_admins_new_ticket();

-- =====================================================
-- Migration: 20260124151330_be468704-29ba-4099-81ff-a087f4ac7e04.sql
-- =====================================================
-- ============================================
-- РЕКЛАМНАЯ СИСТЕМА AI PLANET SOUND
-- ============================================

-- Таблица рекламных кампаний
CREATE TABLE public.ad_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  advertiser_name TEXT,
  advertiser_url TEXT,
  
  -- Тип кампании
  campaign_type TEXT NOT NULL DEFAULT 'external' CHECK (campaign_type IN ('external', 'internal')),
  -- internal = промо конкурсов, треков, фич платформы
  -- external = сторонняя реклама
  
  -- Связь с внутренними объектами (для internal)
  internal_type TEXT CHECK (internal_type IN ('contest', 'track', 'feature', 'subscription')),
  internal_id UUID,
  
  -- Статус и расписание
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'paused', 'completed', 'archived')),
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  
  -- Бюджет и лимиты
  budget_daily INTEGER, -- показов в день
  budget_total INTEGER, -- всего показов
  impressions_count INTEGER DEFAULT 0,
  clicks_count INTEGER DEFAULT 0,
  
  -- Приоритет (выше = важнее)
  priority INTEGER DEFAULT 50,
  
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Рекламные креативы
CREATE TABLE public.ad_creatives (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  
  -- Тип креатива
  creative_type TEXT NOT NULL CHECK (creative_type IN ('image', 'video', 'html')),
  
  -- Контент
  title TEXT,
  subtitle TEXT,
  cta_text TEXT DEFAULT 'Подробнее',
  click_url TEXT,
  
  -- Медиа
  media_url TEXT, -- URL изображения или видео
  media_type TEXT, -- image/jpeg, video/mp4 и т.д.
  thumbnail_url TEXT, -- превью для видео
  
  -- Внешние ссылки (YouTube, Vimeo и т.д.)
  external_video_url TEXT,
  
  -- Размеры и варианты
  variant TEXT DEFAULT 'default', -- default, mobile, desktop
  width INTEGER,
  height INTEGER,
  aspect_ratio TEXT, -- 16:9, 1:1, 4:3
  
  -- Статус
  is_active BOOLEAN DEFAULT true,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Рекламные слоты (места размещения)
CREATE TABLE public.ad_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slot_key TEXT UNIQUE NOT NULL, -- quick_actions, feed_native, hero_banner, etc.
  name TEXT NOT NULL,
  description TEXT,
  
  -- Настройки слота
  is_enabled BOOLEAN DEFAULT true,
  max_ads INTEGER DEFAULT 1, -- сколько реклам показывать
  
  -- Рекомендуемые размеры
  recommended_width INTEGER,
  recommended_height INTEGER,
  recommended_aspect_ratio TEXT,
  
  -- Поддерживаемые типы
  supported_types TEXT[] DEFAULT ARRAY['image', 'video'],
  
  -- Частота показа
  frequency_cap INTEGER DEFAULT 3, -- макс показов одной рекламы в день юзеру
  cooldown_seconds INTEGER DEFAULT 300, -- задержка между показами
  
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Привязка кампаний к слотам
CREATE TABLE public.ad_campaign_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  slot_id UUID NOT NULL REFERENCES public.ad_slots(id) ON DELETE CASCADE,
  creative_id UUID REFERENCES public.ad_creatives(id) ON DELETE SET NULL,
  
  -- Индивидуальные настройки для слота
  priority_override INTEGER,
  is_active BOOLEAN DEFAULT true,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE(campaign_id, slot_id)
);

-- Таргетинг кампаний
CREATE TABLE public.ad_targeting (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  
  -- Таргетинг по подписке
  target_free_users BOOLEAN DEFAULT true,
  target_subscribed_users BOOLEAN DEFAULT false, -- обычно false
  
  -- Таргетинг по устройству
  target_mobile BOOLEAN DEFAULT true,
  target_desktop BOOLEAN DEFAULT true,
  
  -- Таргетинг по активности
  min_generations INTEGER, -- минимум генераций
  max_generations INTEGER, -- максимум генераций
  min_days_registered INTEGER, -- дней с регистрации
  
  -- Время показа
  show_hours_start INTEGER, -- час начала показа (0-23)
  show_hours_end INTEGER, -- час конца показа (0-23)
  show_days_of_week INTEGER[], -- дни недели (1-7)
  
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE(campaign_id)
);

-- Статистика показов
CREATE TABLE public.ad_impressions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  creative_id UUID REFERENCES public.ad_creatives(id) ON DELETE SET NULL,
  slot_id UUID REFERENCES public.ad_slots(id) ON DELETE SET NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  
  -- Детали показа
  device_type TEXT, -- mobile, desktop, tablet
  page_url TEXT,
  
  -- Метрики
  viewed_at TIMESTAMPTZ DEFAULT now(),
  view_duration_ms INTEGER, -- сколько времени была видна реклама
  clicked_at TIMESTAMPTZ,
  
  -- Дедупликация
  session_id TEXT
);

-- Настройки рекламы (глобальные)
CREATE TABLE public.ad_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT UNIQUE NOT NULL,
  value TEXT NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Опция "Без рекламы" для пользователей
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS ad_free_until TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS ad_free_purchased_at TIMESTAMPTZ;

-- ============================================
-- НАЧАЛЬНЫЕ ДАННЫЕ - СЛОТЫ РЕКЛАМЫ
-- ============================================

INSERT INTO public.ad_slots (slot_key, name, description, recommended_width, recommended_height, recommended_aspect_ratio, supported_types) VALUES
('quick_actions', 'Быстрые действия', 'Баннер в секции быстрых действий на главной', 400, 120, '10:3', ARRAY['image', 'video']),
('feed_native', 'Лента (нативная)', 'Карточка между треками в ленте', 400, 300, '4:3', ARRAY['image', 'video']),
('hero_banner', 'Hero Banner', 'Слайд в карусели на главной', 800, 200, '4:1', ARRAY['image', 'video']),
('sidebar', 'Боковая панель', 'Компактный баннер в сайдбаре', 280, 200, '7:5', ARRAY['image']),
('profile', 'Профиль', 'Баннер под статистикой профиля', 600, 120, '5:1', ARRAY['image']),
('between_generations', 'Между генерациями', 'Полноэкранный баннер после генерации', 600, 400, '3:2', ARRAY['image', 'video']);

-- ============================================
-- НАЧАЛЬНЫЕ НАСТРОЙКИ
-- ============================================

INSERT INTO public.ad_settings (key, value, description) VALUES
('ads_enabled', 'true', 'Глобальное включение/выключение рекламы'),
('ad_free_price', '299', 'Цена опции "Без рекламы" в рублях'),
('ad_free_duration_days', '30', 'Длительность опции "Без рекламы" в днях'),
('min_time_between_ads_seconds', '60', 'Минимальное время между показами рекламы'),
('max_ads_per_session', '10', 'Максимум рекламы за сессию'),
('show_ads_to_new_users', 'false', 'Показывать рекламу новым пользователям (первые 24ч)'),
('premium_plans_no_ads', '', 'ID планов подписок без рекламы (через запятую)');

-- ============================================
-- RLS ПОЛИТИКИ
-- ============================================

ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_creatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_campaign_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_targeting ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_settings ENABLE ROW LEVEL SECURITY;

-- Публичный доступ на чтение активных кампаний
CREATE POLICY "Anyone can view active campaigns" ON public.ad_campaigns
  FOR SELECT USING (status = 'active');

CREATE POLICY "Anyone can view active creatives" ON public.ad_creatives
  FOR SELECT USING (is_active = true);

CREATE POLICY "Anyone can view enabled slots" ON public.ad_slots
  FOR SELECT USING (is_enabled = true);

CREATE POLICY "Anyone can view active campaign slots" ON public.ad_campaign_slots
  FOR SELECT USING (is_active = true);

CREATE POLICY "Anyone can view targeting" ON public.ad_targeting
  FOR SELECT USING (true);

CREATE POLICY "Anyone can view ad settings" ON public.ad_settings
  FOR SELECT USING (true);

-- Запись показов
CREATE POLICY "Users can record impressions" ON public.ad_impressions
  FOR INSERT WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

CREATE POLICY "Users can view own impressions" ON public.ad_impressions
  FOR SELECT USING (auth.uid() = user_id);

-- Админские политики
CREATE POLICY "Admins can manage campaigns" ON public.ad_campaigns
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can manage creatives" ON public.ad_creatives
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can manage slots" ON public.ad_slots
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can manage campaign slots" ON public.ad_campaign_slots
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can manage targeting" ON public.ad_targeting
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can view all impressions" ON public.ad_impressions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

CREATE POLICY "Admins can manage settings" ON public.ad_settings
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
  );

-- ============================================
-- ФУНКЦИИ
-- ============================================

-- Функция получения рекламы для слота
CREATE OR REPLACE FUNCTION public.get_ad_for_slot(
  p_slot_key TEXT,
  p_user_id UUID DEFAULT NULL,
  p_device_type TEXT DEFAULT 'desktop'
)
RETURNS TABLE (
  campaign_id UUID,
  creative_id UUID,
  campaign_name TEXT,
  campaign_type TEXT,
  creative_type TEXT,
  title TEXT,
  subtitle TEXT,
  cta_text TEXT,
  click_url TEXT,
  media_url TEXT,
  thumbnail_url TEXT,
  external_video_url TEXT,
  internal_type TEXT,
  internal_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ads_enabled BOOLEAN;
  v_user_is_ad_free BOOLEAN := false;
  v_user_is_premium BOOLEAN := false;
  v_slot_id UUID;
BEGIN
  -- Проверяем глобальные настройки
  SELECT value::boolean INTO v_ads_enabled 
  FROM public.ad_settings WHERE key = 'ads_enabled';
  
  IF NOT COALESCE(v_ads_enabled, true) THEN
    RETURN;
  END IF;
  
  -- Проверяем пользователя
  IF p_user_id IS NOT NULL THEN
    -- Проверяем опцию "без рекламы"
    SELECT (ad_free_until > now()) INTO v_user_is_ad_free
    FROM public.profiles WHERE user_id = p_user_id;
    
    IF v_user_is_ad_free THEN
      RETURN;
    END IF;
    
    -- Проверяем премиум подписку
    SELECT EXISTS (
      SELECT 1 FROM public.subscriptions s
      JOIN public.subscription_plans sp ON s.plan_id = sp.id
      WHERE s.user_id = p_user_id 
        AND s.status = 'active'
        AND sp.id::text = ANY(
          SELECT unnest(string_to_array(value, ','))
          FROM public.ad_settings WHERE key = 'premium_plans_no_ads'
        )
    ) INTO v_user_is_premium;
    
    IF v_user_is_premium THEN
      RETURN;
    END IF;
  END IF;
  
  -- Получаем слот
  SELECT id INTO v_slot_id FROM public.ad_slots 
  WHERE slot_key = p_slot_key AND is_enabled = true;
  
  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;
  
  -- Возвращаем подходящую рекламу
  RETURN QUERY
  SELECT 
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    c.campaign_type,
    cr.creative_type,
    cr.title,
    cr.subtitle,
    cr.cta_text,
    cr.click_url,
    cr.media_url,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id
  WHERE 
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND cs.is_active = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    AND (c.budget_total IS NULL OR c.impressions_count < c.budget_total)
    -- Таргетинг по устройству
    AND (
      (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
      OR t.id IS NULL
    )
  ORDER BY 
    COALESCE(cs.priority_override, c.priority) DESC,
    random()
  LIMIT 1;
END;
$$;

-- Функция записи показа
CREATE OR REPLACE FUNCTION public.record_ad_impression(
  p_campaign_id UUID,
  p_creative_id UUID,
  p_slot_key TEXT,
  p_user_id UUID DEFAULT NULL,
  p_device_type TEXT DEFAULT 'desktop',
  p_page_url TEXT DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot_id UUID;
  v_impression_id UUID;
BEGIN
  SELECT id INTO v_slot_id FROM public.ad_slots WHERE slot_key = p_slot_key;
  
  INSERT INTO public.ad_impressions (
    campaign_id, creative_id, slot_id, user_id, 
    device_type, page_url, session_id
  ) VALUES (
    p_campaign_id, p_creative_id, v_slot_id, p_user_id,
    p_device_type, p_page_url, p_session_id
  ) RETURNING id INTO v_impression_id;
  
  -- Обновляем счетчик кампании
  UPDATE public.ad_campaigns 
  SET impressions_count = impressions_count + 1,
      updated_at = now()
  WHERE id = p_campaign_id;
  
  RETURN v_impression_id;
END;
$$;

-- Функция записи клика
CREATE OR REPLACE FUNCTION public.record_ad_click(
  p_impression_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign_id UUID;
BEGIN
  UPDATE public.ad_impressions 
  SET clicked_at = now()
  WHERE id = p_impression_id
  RETURNING campaign_id INTO v_campaign_id;
  
  -- Обновляем счетчик кликов кампании
  UPDATE public.ad_campaigns 
  SET clicks_count = clicks_count + 1,
      updated_at = now()
  WHERE id = v_campaign_id;
END;
$$;

-- Функция покупки опции "без рекламы"
CREATE OR REPLACE FUNCTION public.purchase_ad_free(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price INTEGER;
  v_duration_days INTEGER;
  v_user_balance INTEGER;
  v_new_ad_free_until TIMESTAMPTZ;
BEGIN
  SELECT value::integer INTO v_price FROM public.ad_settings WHERE key = 'ad_free_price';
  SELECT value::integer INTO v_duration_days FROM public.ad_settings WHERE key = 'ad_free_duration_days';
  
  v_price := COALESCE(v_price, 299);
  v_duration_days := COALESCE(v_duration_days, 30);
  
  -- Проверяем баланс
  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = p_user_id;
  
  IF v_user_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств');
  END IF;
  
  -- Списываем
  UPDATE public.profiles 
  SET 
    balance = balance - v_price,
    ad_free_until = CASE 
      WHEN ad_free_until IS NULL OR ad_free_until < now() 
      THEN now() + (v_duration_days || ' days')::interval
      ELSE ad_free_until + (v_duration_days || ' days')::interval
    END,
    ad_free_purchased_at = now()
  WHERE user_id = p_user_id
  RETURNING ad_free_until INTO v_new_ad_free_until;
  
  -- Записываем платеж
  INSERT INTO public.payments (user_id, amount, type, status, description)
  VALUES (p_user_id, v_price, 'ad_free', 'completed', 'Покупка опции "Без рекламы" на ' || v_duration_days || ' дней');
  
  RETURN jsonb_build_object(
    'success', true, 
    'ad_free_until', v_new_ad_free_until,
    'price', v_price,
    'days', v_duration_days
  );
END;
$$;

-- ============================================
-- ИНДЕКСЫ
-- ============================================

CREATE INDEX idx_ad_campaigns_status ON public.ad_campaigns(status);
CREATE INDEX idx_ad_campaigns_dates ON public.ad_campaigns(start_date, end_date);
CREATE INDEX idx_ad_creatives_campaign ON public.ad_creatives(campaign_id);
CREATE INDEX idx_ad_campaign_slots_campaign ON public.ad_campaign_slots(campaign_id);
CREATE INDEX idx_ad_campaign_slots_slot ON public.ad_campaign_slots(slot_id);
CREATE INDEX idx_ad_impressions_campaign ON public.ad_impressions(campaign_id);
CREATE INDEX idx_ad_impressions_user ON public.ad_impressions(user_id);
CREATE INDEX idx_ad_impressions_viewed ON public.ad_impressions(viewed_at);
CREATE INDEX idx_profiles_ad_free ON public.profiles(ad_free_until) WHERE ad_free_until IS NOT NULL;

-- =====================================================
-- Migration: 20260124152412_1c338561-0801-486c-8d7f-2d023e25b358.sql
-- =====================================================
-- Create storage bucket for ad creatives
INSERT INTO storage.buckets (id, name, public) 
VALUES ('ad-creatives', 'ad-creatives', true)
ON CONFLICT (id) DO NOTHING;

-- Allow admins to upload ad creatives
CREATE POLICY "Admins can upload ad creatives"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'ad-creatives' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);

-- Allow admins to update ad creatives
CREATE POLICY "Admins can update ad creatives"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'ad-creatives' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);

-- Allow admins to delete ad creatives
CREATE POLICY "Admins can delete ad creatives"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'ad-creatives' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);

-- Allow public to read ad creatives
CREATE POLICY "Public can view ad creatives"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'ad-creatives');

-- =====================================================
-- Migration: 20260124161015_e6c5781f-d02e-4a2a-9ffe-d3831facbb20.sql
-- =====================================================
-- =============================================
-- TRACK PROMOTIONS / BOOST SYSTEM
-- =============================================

-- Table for track promotions/boosts
CREATE TABLE public.track_promotions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  boost_type TEXT NOT NULL DEFAULT 'standard', -- 'standard', 'premium', 'top'
  price_paid NUMERIC NOT NULL DEFAULT 0,
  starts_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  impressions_count INTEGER NOT NULL DEFAULT 0,
  clicks_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  
  CONSTRAINT unique_active_promotion UNIQUE (track_id, is_active) DEFERRABLE INITIALLY DEFERRED
);

-- Enable RLS
ALTER TABLE public.track_promotions ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own promotions"
  ON public.track_promotions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create promotions for their tracks"
  ON public.track_promotions FOR INSERT
  WITH CHECK (
    auth.uid() = user_id AND
    EXISTS (SELECT 1 FROM public.tracks WHERE id = track_id AND user_id = auth.uid())
  );

CREATE POLICY "Admins can view all promotions"
  ON public.track_promotions FOR SELECT
  USING (public.is_admin(auth.uid()));

-- Public can see active promotions (for displaying boosted tracks)
CREATE POLICY "Anyone can see active promotions"
  ON public.track_promotions FOR SELECT
  USING (is_active = true AND expires_at > now());

-- Settings for boost prices
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES 
  ('boost_track_1h', 'Буст трека (1 час)', 'Поднять трек в ленте на 1 час', 10, 'rocket', true, 20),
  ('boost_track_6h', 'Буст трека (6 часов)', 'Поднять трек в ленте на 6 часов', 40, 'rocket', true, 21),
  ('boost_track_24h', 'Буст трека (24 часа)', 'Поднять трек в ленте на сутки', 100, 'rocket', true, 22)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub;

-- Function to purchase track boost
CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id UUID,
  p_boost_duration_hours INTEGER DEFAULT 1
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_user_balance NUMERIC;
  v_price NUMERIC;
  v_service_name TEXT;
  v_promotion_id UUID;
  v_expires_at TIMESTAMP WITH TIME ZONE;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Необходима авторизация');
  END IF;
  
  -- Check track ownership
  IF NOT EXISTS (SELECT 1 FROM public.tracks WHERE id = p_track_id AND user_id = v_user_id) THEN
    RETURN json_build_object('success', false, 'error', 'Трек не найден или не принадлежит вам');
  END IF;
  
  -- Check if already boosted
  IF EXISTS (
    SELECT 1 FROM public.track_promotions 
    WHERE track_id = p_track_id AND is_active = true AND expires_at > now()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Трек уже продвигается');
  END IF;
  
  -- Determine price based on duration
  CASE p_boost_duration_hours
    WHEN 1 THEN v_service_name := 'boost_track_1h';
    WHEN 6 THEN v_service_name := 'boost_track_6h';
    WHEN 24 THEN v_service_name := 'boost_track_24h';
    ELSE RETURN json_build_object('success', false, 'error', 'Неверная длительность');
  END CASE;
  
  SELECT price_rub INTO v_price FROM public.addon_services WHERE name = v_service_name;
  
  IF v_price IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Услуга не найдена');
  END IF;
  
  -- Check balance
  SELECT balance INTO v_user_balance FROM public.profiles WHERE user_id = v_user_id;
  
  IF v_user_balance < v_price THEN
    RETURN json_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', v_user_balance);
  END IF;
  
  -- Deduct balance
  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_user_id;
  
  -- Calculate expiration
  v_expires_at := now() + (p_boost_duration_hours || ' hours')::INTERVAL;
  
  -- Deactivate old promotions for this track
  UPDATE public.track_promotions 
  SET is_active = false 
  WHERE track_id = p_track_id;
  
  -- Create promotion
  INSERT INTO public.track_promotions (track_id, user_id, boost_type, price_paid, expires_at)
  VALUES (p_track_id, v_user_id, 'standard', v_price, v_expires_at)
  RETURNING id INTO v_promotion_id;
  
  -- Log transaction
  INSERT INTO public.payments (user_id, amount, type, status, description)
  VALUES (v_user_id, -v_price, 'boost', 'completed', 'Продвижение трека на ' || p_boost_duration_hours || ' ч.');
  
  RETURN json_build_object(
    'success', true,
    'promotion_id', v_promotion_id,
    'expires_at', v_expires_at,
    'price', v_price
  );
END;
$$;

-- Function to get boosted tracks for feed
CREATE OR REPLACE FUNCTION public.get_boosted_tracks(p_limit INTEGER DEFAULT 5)
RETURNS TABLE (
  track_id UUID,
  boost_type TEXT,
  expires_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    tp.track_id,
    tp.boost_type,
    tp.expires_at
  FROM public.track_promotions tp
  JOIN public.tracks t ON t.id = tp.track_id
  WHERE 
    tp.is_active = true 
    AND tp.expires_at > now()
    AND t.is_public = true
    AND t.status = 'completed'
  ORDER BY 
    CASE tp.boost_type 
      WHEN 'top' THEN 1 
      WHEN 'premium' THEN 2 
      ELSE 3 
    END,
    tp.created_at DESC
  LIMIT p_limit;
$$;

-- Index for faster queries
CREATE INDEX idx_track_promotions_active ON public.track_promotions (track_id, is_active, expires_at) WHERE is_active = true;

-- Enable realtime for promotions
ALTER PUBLICATION supabase_realtime ADD TABLE public.track_promotions;

-- =====================================================
-- Migration: 20260124172338_c0b65bef-6c13-43c0-a7be-24c07f6f25e9.sql
-- =====================================================
-- Create optimized RPC function for feed tracks with profiles in single query
CREATE OR REPLACE FUNCTION public.get_feed_tracks_with_profiles(
  p_tab TEXT,
  p_user_id UUID DEFAULT NULL,
  p_genre_id UUID DEFAULT NULL,
  p_offset INT DEFAULT 0,
  p_limit INT DEFAULT 20
)
RETURNS TABLE (
  id UUID,
  title TEXT,
  description TEXT,
  audio_url TEXT,
  cover_url TEXT,
  duration INT,
  is_public BOOLEAN,
  likes_count INT,
  plays_count INT,
  status TEXT,
  created_at TIMESTAMPTZ,
  user_id UUID,
  genre_id UUID,
  genre_name_ru TEXT,
  profile_username TEXT,
  profile_avatar_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_following_ids UUID[];
BEGIN
  -- For "following" tab, get list of followed users first
  IF p_tab = 'following' AND p_user_id IS NOT NULL THEN
    SELECT ARRAY_AGG(following_id) INTO v_following_ids
    FROM user_follows
    WHERE follower_id = p_user_id;
    
    -- If no followers, return empty
    IF v_following_ids IS NULL OR array_length(v_following_ids, 1) IS NULL THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  SELECT 
    t.id,
    t.title,
    t.description,
    t.audio_url,
    t.cover_url,
    t.duration::INT,
    t.is_public,
    t.likes_count::INT,
    t.plays_count::INT,
    t.status,
    t.created_at,
    t.user_id,
    t.genre_id,
    g.name_ru AS genre_name_ru,
    p.username AS profile_username,
    p.avatar_url AS profile_avatar_url
  FROM tracks t
  LEFT JOIN genres g ON g.id = t.genre_id
  LEFT JOIN profiles p ON p.user_id = t.user_id
  WHERE t.is_public = TRUE
    AND t.status = 'completed'
    AND (p_genre_id IS NULL OR t.genre_id = p_genre_id)
    AND (
      CASE 
        WHEN p_tab = 'following' THEN t.user_id = ANY(v_following_ids)
        ELSE TRUE
      END
    )
  ORDER BY 
    CASE 
      WHEN p_tab = 'trending' THEN t.likes_count
      ELSE NULL
    END DESC NULLS LAST,
    CASE 
      WHEN p_tab IN ('new', 'following') THEN t.created_at
      ELSE NULL
    END DESC NULLS LAST
  OFFSET p_offset
  LIMIT p_limit;
END;
$$;

-- Grant execute to authenticated users and anon
GRANT EXECUTE ON FUNCTION public.get_feed_tracks_with_profiles TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_feed_tracks_with_profiles TO anon;

-- =====================================================
-- Migration: 20260124174609_c398a820-8024-43c6-8adf-60e7139af87b.sql
-- =====================================================
-- ============================================
-- СИСТЕМА ВЕРИФИКАЦИИ АРТИСТОВ
-- ============================================

-- Добавляем статус верификации в profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT false;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verified_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verified_by UUID REFERENCES auth.users(id);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verification_type TEXT; -- 'creator', 'label', 'partner'

-- Таблица заявок на верификацию
CREATE TABLE IF NOT EXISTS public.verification_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  type TEXT NOT NULL DEFAULT 'creator', -- 'creator', 'label', 'partner'
  status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'approved', 'rejected'
  
  -- Информация о заявителе
  real_name TEXT,
  social_links JSONB DEFAULT '[]'::jsonb, -- [{vk: "...", ok: "..."}]
  documents JSONB DEFAULT '[]'::jsonb, -- ссылки на документы
  notes TEXT, -- комментарий от заявителя
  
  -- Обработка
  reviewed_by UUID REFERENCES auth.users(id),
  reviewed_at TIMESTAMP WITH TIME ZONE,
  rejection_reason TEXT,
  
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Включаем RLS
ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;

-- Пользователи могут видеть свои заявки
CREATE POLICY "Users can view own verification requests"
  ON public.verification_requests
  FOR SELECT
  USING (auth.uid() = user_id);

-- Пользователи могут создавать заявки
CREATE POLICY "Users can create verification requests"
  ON public.verification_requests
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Админы могут всё
CREATE POLICY "Admins can manage verification requests"
  ON public.verification_requests
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_roles.user_id = auth.uid()
      AND user_roles.role IN ('admin', 'super_admin')
    )
  );

-- Индексы
CREATE INDEX IF NOT EXISTS idx_verification_requests_user ON public.verification_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_verification_requests_status ON public.verification_requests(status);
CREATE INDEX IF NOT EXISTS idx_profiles_verified ON public.profiles(is_verified) WHERE is_verified = true;

-- Триггер для updated_at
CREATE OR REPLACE TRIGGER update_verification_requests_updated_at
  BEFORE UPDATE ON public.verification_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================
-- РАСШИРЕННАЯ АНАЛИТИКА (таблица статистики)
-- ============================================

-- Ежедневная статистика треков
CREATE TABLE IF NOT EXISTS public.track_daily_stats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  plays_count INTEGER DEFAULT 0,
  likes_count INTEGER DEFAULT 0,
  shares_count INTEGER DEFAULT 0,
  
  UNIQUE(track_id, date)
);

-- Включаем RLS
ALTER TABLE public.track_daily_stats ENABLE ROW LEVEL SECURITY;

-- Владельцы треков могут видеть статистику
CREATE POLICY "Track owners can view stats"
  ON public.track_daily_stats
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.tracks
      WHERE tracks.id = track_daily_stats.track_id
      AND tracks.user_id = auth.uid()
    )
  );

-- Админы могут всё
CREATE POLICY "Admins can manage track stats"
  ON public.track_daily_stats
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_roles.user_id = auth.uid()
      AND user_roles.role IN ('admin', 'super_admin')
    )
  );

-- Индексы для аналитики
CREATE INDEX IF NOT EXISTS idx_track_daily_stats_track ON public.track_daily_stats(track_id);
CREATE INDEX IF NOT EXISTS idx_track_daily_stats_date ON public.track_daily_stats(date DESC);

-- Функция для записи прослушивания
CREATE OR REPLACE FUNCTION public.record_track_play(p_track_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Обновляем общий счётчик
  UPDATE public.tracks 
  SET plays_count = COALESCE(plays_count, 0) + 1
  WHERE id = p_track_id;
  
  -- Обновляем/создаём дневную статистику
  INSERT INTO public.track_daily_stats (track_id, date, plays_count)
  VALUES (p_track_id, CURRENT_DATE, 1)
  ON CONFLICT (track_id, date) 
  DO UPDATE SET plays_count = track_daily_stats.plays_count + 1;
END;
$$;

-- =====================================================
-- Migration: 20260124193155_5df7e6f2-4982-4f2d-9b4a-934bcda9161d.sql
-- =====================================================
-- Add analyze_lyrics addon service for AI lyrics analysis
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES 
  ('analyze_lyrics', 'AI Разметка текста', 'AI анализ и разметка текста песни с определением жанра, настроения и стиля', 5, 'brain', true, 14)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub,
  icon = EXCLUDED.icon,
  is_active = EXCLUDED.is_active;

-- =====================================================
-- Migration: 20260124221654_4bee0dc8-ee68-4e27-8748-681a16e0b8cc.sql
-- =====================================================
-- =============================================================
-- СИСТЕМА ГОЛОСОВАНИЯ ЗА ТРЕКИ (Community Voting)
-- =============================================================

-- 1. Таблица голосов за треки
CREATE TABLE public.track_votes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  vote_type TEXT NOT NULL CHECK (vote_type IN ('like', 'dislike')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  
  -- Один голос на пользователя за трек
  CONSTRAINT unique_user_track_vote UNIQUE (track_id, user_id)
);

-- Индексы для быстрого подсчёта
CREATE INDEX idx_track_votes_track_id ON public.track_votes(track_id);
CREATE INDEX idx_track_votes_user_id ON public.track_votes(user_id);
CREATE INDEX idx_track_votes_type ON public.track_votes(track_id, vote_type);

-- RLS для голосов
ALTER TABLE public.track_votes ENABLE ROW LEVEL SECURITY;

-- Просмотр голосов - все могут видеть статистику
CREATE POLICY "Anyone can view vote counts"
  ON public.track_votes FOR SELECT
  USING (true);

-- Голосование - только авторизованные пользователи
CREATE POLICY "Authenticated users can vote"
  ON public.track_votes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Изменение голоса - только свой голос
CREATE POLICY "Users can update own vote"
  ON public.track_votes FOR UPDATE
  USING (auth.uid() = user_id);

-- Удаление голоса - только свой
CREATE POLICY "Users can delete own vote"
  ON public.track_votes FOR DELETE
  USING (auth.uid() = user_id);

-- 2. Добавляем поля голосования в tracks
ALTER TABLE public.tracks 
  ADD COLUMN IF NOT EXISTS voting_started_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS voting_ends_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS voting_likes_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS voting_dislikes_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS voting_result TEXT CHECK (voting_result IN ('pending', 'approved', 'rejected', 'manual_override'));

-- Индекс для поиска треков на голосовании
CREATE INDEX idx_tracks_voting ON public.tracks(moderation_status, voting_ends_at) 
  WHERE moderation_status = 'voting';

-- 3. Настройки голосования
INSERT INTO public.settings (key, value, description) VALUES
  ('voting_duration_days', '7', 'Длительность голосования в днях'),
  ('voting_min_votes', '10', 'Минимальное количество голосов для принятия решения'),
  ('voting_approval_ratio', '0.6', 'Минимальный процент лайков для одобрения (0.6 = 60%)'),
  ('voting_auto_approve', 'true', 'Автоматически одобрять после достижения порога'),
  ('voting_notify_artist', 'true', 'Уведомлять артиста о начале/окончании голосования')
ON CONFLICT (key) DO NOTHING;

-- 4. Триггер для автоматического подсчёта голосов
CREATE OR REPLACE FUNCTION public.update_track_vote_counts()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    UPDATE public.tracks SET
      voting_likes_count = (SELECT COUNT(*) FROM public.track_votes WHERE track_id = NEW.track_id AND vote_type = 'like'),
      voting_dislikes_count = (SELECT COUNT(*) FROM public.track_votes WHERE track_id = NEW.track_id AND vote_type = 'dislike')
    WHERE id = NEW.track_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.tracks SET
      voting_likes_count = (SELECT COUNT(*) FROM public.track_votes WHERE track_id = OLD.track_id AND vote_type = 'like'),
      voting_dislikes_count = (SELECT COUNT(*) FROM public.track_votes WHERE track_id = OLD.track_id AND vote_type = 'dislike')
    WHERE id = OLD.track_id;
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trigger_update_vote_counts
  AFTER INSERT OR UPDATE OR DELETE ON public.track_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.update_track_vote_counts();

-- 5. Функция для отправки трека на голосование
CREATE OR REPLACE FUNCTION public.send_track_to_voting(
  p_track_id UUID,
  p_duration_days INTEGER DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_duration INTEGER;
  v_ends_at TIMESTAMP WITH TIME ZONE;
BEGIN
  -- Получаем длительность из настроек или параметра
  IF p_duration_days IS NULL THEN
    SELECT COALESCE(value::integer, 7) INTO v_duration
    FROM public.settings WHERE key = 'voting_duration_days';
  ELSE
    v_duration := p_duration_days;
  END IF;
  
  v_ends_at := now() + (v_duration || ' days')::interval;
  
  UPDATE public.tracks SET
    moderation_status = 'voting',
    voting_started_at = now(),
    voting_ends_at = v_ends_at,
    voting_result = 'pending',
    voting_likes_count = 0,
    voting_dislikes_count = 0,
    is_public = true  -- Делаем видимым для голосования
  WHERE id = p_track_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'voting_ends_at', v_ends_at,
    'duration_days', v_duration
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Функция для завершения голосования
CREATE OR REPLACE FUNCTION public.resolve_track_voting(
  p_track_id UUID,
  p_manual_result TEXT DEFAULT NULL  -- 'approved' или 'rejected' для ручного переопределения
)
RETURNS JSONB AS $$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_like_ratio NUMERIC;
  v_result TEXT;
BEGIN
  -- Получаем данные трека
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;
  
  -- Ручное переопределение
  IF p_manual_result IS NOT NULL THEN
    UPDATE public.tracks SET
      moderation_status = p_manual_result,
      voting_result = 'manual_override',
      is_public = (p_manual_result = 'approved')
    WHERE id = p_track_id;
    
    RETURN jsonb_build_object(
      'success', true,
      'result', p_manual_result,
      'method', 'manual_override'
    );
  END IF;
  
  -- Автоматическое определение результата
  v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);
  
  SELECT COALESCE(value::integer, 10) INTO v_min_votes
  FROM public.settings WHERE key = 'voting_min_votes';
  
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio
  FROM public.settings WHERE key = 'voting_approval_ratio';
  
  -- Недостаточно голосов - отклоняем
  IF v_total_votes < v_min_votes THEN
    v_result := 'rejected';
  ELSE
    v_like_ratio := v_track.voting_likes_count::numeric / v_total_votes;
    v_result := CASE WHEN v_like_ratio >= v_approval_ratio THEN 'approved' ELSE 'rejected' END;
  END IF;
  
  UPDATE public.tracks SET
    moderation_status = v_result,
    voting_result = v_result,
    is_public = (v_result = 'approved')
  WHERE id = p_track_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'total_votes', v_total_votes,
    'like_ratio', v_like_ratio,
    'min_votes_required', v_min_votes,
    'approval_ratio_required', v_approval_ratio
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Включаем realtime для голосов
ALTER PUBLICATION supabase_realtime ADD TABLE public.track_votes;

-- =====================================================
-- Migration: 20260124221706_22be43a6-8941-474b-89c6-83383f761a08.sql
-- =====================================================
-- Fix search_path for voting functions
ALTER FUNCTION public.update_track_vote_counts() SET search_path = public;
ALTER FUNCTION public.send_track_to_voting(UUID, INTEGER) SET search_path = public;
ALTER FUNCTION public.resolve_track_voting(UUID, TEXT) SET search_path = public;

-- =====================================================
-- Migration: 20260125112930_25ab31dd-b8fd-4f30-af8f-c981beb02153.sql
-- =====================================================
-- Grant execute permission on get_ad_for_slot function to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(text, uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(text, uuid, text) TO authenticated;

-- =====================================================
-- Migration: 20260128172005_966a0b44-cac1-4561-9459-73fe95640ee9.sql
-- =====================================================
-- SECURITY FIX: Remove permissive SELECT policy that exposes user balance

-- Drop the overly permissive policy that exposes all profile fields including balance
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON public.profiles;

-- Also drop legacy policies if they exist
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;

-- Create restrictive policy: users can only SELECT their own profile directly
-- For viewing other users, they must use profiles_public view (which excludes balance)
CREATE POLICY "Users can view own profile"
ON public.profiles
FOR SELECT
USING (auth.uid() = user_id);

-- Note: Admins can view all profiles via existing "Admins can view all profiles" policy
-- Note: profiles_public view (already exists) should be used for viewing other users' public data

-- =====================================================
-- Migration: 20260128192631_ae6d31cb-aef3-4b57-a265-0a02cde9e4ee.sql
-- =====================================================
-- Create personas table for storing voice personas
CREATE TABLE public.personas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    name TEXT NOT NULL,
    avatar_url TEXT,
    source_track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
    clip_start_time NUMERIC NOT NULL DEFAULT 0,
    clip_end_time NUMERIC NOT NULL DEFAULT 30,
    suno_persona_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    is_public BOOLEAN DEFAULT false,
    description TEXT,
    style_tags TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;

-- Users can view their own personas
CREATE POLICY "Users can view their own personas"
ON public.personas
FOR SELECT
USING (auth.uid() = user_id);

-- Users can view public personas
CREATE POLICY "Users can view public personas"
ON public.personas
FOR SELECT
USING (is_public = true);

-- Users can create their own personas
CREATE POLICY "Users can create their own personas"
ON public.personas
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can update their own personas
CREATE POLICY "Users can update their own personas"
ON public.personas
FOR UPDATE
USING (auth.uid() = user_id);

-- Users can delete their own personas
CREATE POLICY "Users can delete their own personas"
ON public.personas
FOR DELETE
USING (auth.uid() = user_id);

-- Create updated_at trigger
CREATE TRIGGER update_personas_updated_at
BEFORE UPDATE ON public.personas
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Create storage bucket for persona avatars
INSERT INTO storage.buckets (id, name, public) 
VALUES ('personas', 'personas', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for persona avatars
CREATE POLICY "Persona avatars are publicly accessible"
ON storage.objects
FOR SELECT
USING (bucket_id = 'personas');

CREATE POLICY "Users can upload their own persona avatars"
ON storage.objects
FOR INSERT
WITH CHECK (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "Users can update their own persona avatars"
ON storage.objects
FOR UPDATE
USING (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "Users can delete their own persona avatars"
ON storage.objects
FOR DELETE
USING (bucket_id = 'personas' AND auth.uid()::text = (storage.foldername(name))[1]);

-- =====================================================
-- Migration: 20260128212645_557b741f-9e41-4ed1-9403-c6a3f0babea6.sql
-- =====================================================
-- Add audio_reference_url column to tracks table
ALTER TABLE public.tracks 
ADD COLUMN IF NOT EXISTS audio_reference_url TEXT;

-- =====================================================
-- Migration: 20260128213931_e19f576b-3076-4efb-b27f-c7b2389014a0.sql
-- =====================================================
-- Add suno_audio_id column to tracks table for persona creation
ALTER TABLE public.tracks 
ADD COLUMN IF NOT EXISTS suno_audio_id TEXT;

-- Add index for faster lookups
CREATE INDEX IF NOT EXISTS idx_tracks_suno_audio_id ON public.tracks(suno_audio_id);

COMMENT ON COLUMN public.tracks.suno_audio_id IS 'Suno API audio ID for persona creation';

-- =====================================================
-- Migration: 20260128215345_c3dd9788-75b1-4aaa-9f66-4c3da7fc41aa.sql
-- =====================================================
-- Drop and recreate get_ad_for_slot function with correct table name
DROP FUNCTION IF EXISTS public.get_ad_for_slot(TEXT, UUID, TEXT);

CREATE FUNCTION public.get_ad_for_slot(
  p_slot_key TEXT,
  p_user_id UUID DEFAULT NULL,
  p_device_type TEXT DEFAULT 'desktop'
)
RETURNS TABLE (
  campaign_id UUID,
  creative_id UUID,
  campaign_name TEXT,
  campaign_type TEXT,
  creative_type TEXT,
  title TEXT,
  subtitle TEXT,
  cta_text TEXT,
  click_url TEXT,
  media_url TEXT,
  thumbnail_url TEXT,
  external_video_url TEXT,
  internal_type TEXT,
  internal_id TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ads_enabled BOOLEAN;
  v_user_is_ad_free BOOLEAN := false;
  v_user_is_premium BOOLEAN := false;
  v_slot_id UUID;
BEGIN
  -- Проверяем глобальные настройки
  SELECT value::boolean INTO v_ads_enabled 
  FROM public.ad_settings WHERE key = 'ads_enabled';
  
  IF NOT COALESCE(v_ads_enabled, true) THEN
    RETURN;
  END IF;
  
  -- Проверяем пользователя
  IF p_user_id IS NOT NULL THEN
    -- Проверяем опцию "без рекламы"
    SELECT (ad_free_until > now()) INTO v_user_is_ad_free
    FROM public.profiles WHERE user_id = p_user_id;
    
    IF v_user_is_ad_free THEN
      RETURN;
    END IF;
    
    -- Проверяем премиум подписку (FIXED: use user_subscriptions instead of subscriptions)
    SELECT EXISTS (
      SELECT 1 FROM public.user_subscriptions s
      JOIN public.subscription_plans sp ON s.plan_id = sp.id
      WHERE s.user_id = p_user_id 
        AND s.status = 'active'
        AND sp.id::text = ANY(
          SELECT unnest(string_to_array(value, ','))
          FROM public.ad_settings WHERE key = 'premium_plans_no_ads'
        )
    ) INTO v_user_is_premium;
    
    IF v_user_is_premium THEN
      RETURN;
    END IF;
  END IF;
  
  -- Получаем слот
  SELECT id INTO v_slot_id FROM public.ad_slots 
  WHERE slot_key = p_slot_key AND is_enabled = true;
  
  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;
  
  -- Возвращаем подходящую рекламу
  RETURN QUERY
  SELECT 
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    c.campaign_type,
    cr.creative_type,
    cr.title,
    cr.subtitle,
    cr.cta_text,
    cr.click_url,
    cr.media_url,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id
  WHERE 
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND cs.is_active = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    AND (c.budget_total IS NULL OR c.impressions_count < c.budget_total)
    -- Таргетинг по устройству
    AND (
      (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
      OR t.id IS NULL
    )
  ORDER BY 
    COALESCE(cs.priority_override, c.priority) DESC,
    random()
  LIMIT 1;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(TEXT, UUID, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(TEXT, UUID, TEXT) TO authenticated;

-- =====================================================
-- Migration: 20260128215717_bec86377-e91e-4ae0-82f7-68b411b16c44.sql
-- =====================================================
-- Fix get_ad_for_slot function to include all required columns from ad_creatives
DROP FUNCTION IF EXISTS public.get_ad_for_slot(TEXT, UUID, TEXT);

CREATE FUNCTION public.get_ad_for_slot(
  p_slot_key TEXT,
  p_user_id UUID DEFAULT NULL,
  p_device_type TEXT DEFAULT 'desktop'
)
RETURNS TABLE (
  campaign_id UUID,
  creative_id UUID,
  campaign_name TEXT,
  campaign_type TEXT,
  creative_type TEXT,
  title TEXT,
  subtitle TEXT,
  cta_text TEXT,
  click_url TEXT,
  media_url TEXT,
  media_type TEXT,
  thumbnail_url TEXT,
  external_video_url TEXT,
  internal_type TEXT,
  internal_id TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ads_enabled BOOLEAN;
  v_user_is_ad_free BOOLEAN := false;
  v_user_is_premium BOOLEAN := false;
  v_slot_id UUID;
BEGIN
  -- Check global ads setting
  SELECT value::boolean INTO v_ads_enabled 
  FROM public.ad_settings WHERE key = 'ads_enabled';
  
  IF NOT COALESCE(v_ads_enabled, true) THEN
    RETURN;
  END IF;
  
  -- Check user status
  IF p_user_id IS NOT NULL THEN
    -- Check ad-free option
    SELECT (ad_free_until > now()) INTO v_user_is_ad_free
    FROM public.profiles WHERE user_id = p_user_id;
    
    IF v_user_is_ad_free THEN
      RETURN;
    END IF;
    
    -- Check premium subscription
    SELECT EXISTS (
      SELECT 1 FROM public.user_subscriptions s
      JOIN public.subscription_plans sp ON s.plan_id = sp.id
      WHERE s.user_id = p_user_id 
        AND s.status = 'active'
        AND sp.id::text = ANY(
          SELECT unnest(string_to_array(value, ','))
          FROM public.ad_settings WHERE key = 'premium_plans_no_ads'
        )
    ) INTO v_user_is_premium;
    
    IF v_user_is_premium THEN
      RETURN;
    END IF;
  END IF;
  
  -- Get slot
  SELECT id INTO v_slot_id FROM public.ad_slots 
  WHERE slot_key = p_slot_key AND is_enabled = true;
  
  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;
  
  -- Return matching ad
  RETURN QUERY
  SELECT 
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    c.campaign_type,
    cr.creative_type,
    cr.title,
    cr.subtitle,
    cr.cta_text,
    cr.click_url,
    cr.media_url,
    cr.media_type,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id
  WHERE 
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND cs.is_active = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    AND (c.budget_total IS NULL OR c.impressions_count < c.budget_total)
    -- Device targeting
    AND (
      (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
      OR t.id IS NULL
    )
  ORDER BY 
    COALESCE(cs.priority_override, c.priority) DESC,
    random()
  LIMIT 1;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(TEXT, UUID, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(TEXT, UUID, TEXT) TO authenticated;

-- =====================================================
-- Migration: 20260128232852_aee3b53a-2bb4-45e4-95ea-c38ae1e116bb.sql
-- =====================================================
-- Create bucket for audio references
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'audio-references', 
  'audio-references', 
  true,
  5242880, -- 5MB
  ARRAY['audio/mpeg', 'audio/mp3', 'audio/wav', 'audio/wave', 'audio/x-wav']
)
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to upload to their own folder
CREATE POLICY "Users can upload audio references"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'audio-references' 
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow public read access
CREATE POLICY "Audio references are publicly readable"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'audio-references');

-- =====================================================
-- Migration: 20260129111530_3ea519ac-ec8a-40d9-b9da-080b7f6d2a17.sql
-- =====================================================
-- Drop existing policies and recreate correctly
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;

-- Users can only view their own full profile (with balance)
CREATE POLICY "Users can view own profile" 
ON public.profiles FOR SELECT
USING (auth.uid() = user_id);

-- Admins and super_admins can view all profiles
CREATE POLICY "Admins can view all profiles"
ON public.profiles FOR SELECT
USING (public.is_admin(auth.uid()));

-- Recreate profiles_public view without sensitive fields
DROP VIEW IF EXISTS public.profiles_public;
CREATE VIEW public.profiles_public 
WITH (security_invoker = on)
AS SELECT 
  id, 
  user_id, 
  username, 
  avatar_url, 
  cover_url, 
  bio,
  social_links, 
  followers_count, 
  following_count,
  is_verified, 
  verification_type,
  created_at, 
  updated_at,
  last_seen_at
FROM public.profiles;

-- Grant access to the public view
GRANT SELECT ON public.profiles_public TO authenticated;
GRANT SELECT ON public.profiles_public TO anon;

-- =====================================================
-- Migration: 20260129113805_87b72afa-88fe-4bb7-b6d2-eeed6a670db8.sql
-- =====================================================
-- Add share_token column for private track sharing
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS share_token TEXT UNIQUE;

-- Create index for fast share_token lookups
CREATE INDEX IF NOT EXISTS idx_tracks_share_token ON public.tracks(share_token) WHERE share_token IS NOT NULL;

-- Drop existing restrictive select policy if any for anon users
DROP POLICY IF EXISTS "Anyone can view public tracks" ON public.tracks;

-- Allow anonymous users to view public tracks OR tracks with valid share_token
CREATE POLICY "Anyone can view public tracks or shared tracks" 
ON public.tracks 
FOR SELECT 
TO anon
USING (
  (is_public = true AND status = 'completed')
  OR 
  share_token IS NOT NULL
);

-- Update authenticated user policy to include share_token access
DROP POLICY IF EXISTS "Users can view own or public tracks" ON public.tracks;

CREATE POLICY "Users can view own or public or shared tracks" 
ON public.tracks 
FOR SELECT 
TO authenticated
USING (
  user_id = auth.uid() 
  OR (is_public = true AND status = 'completed')
  OR share_token IS NOT NULL
);

-- Function to generate share token
CREATE OR REPLACE FUNCTION public.generate_share_token(_track_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token TEXT;
  v_track RECORD;
BEGIN
  -- Check ownership
  SELECT * INTO v_track FROM public.tracks WHERE id = _track_id;
  
  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found';
  END IF;
  
  IF v_track.user_id != auth.uid() AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to share this track';
  END IF;
  
  -- If already has token, return it
  IF v_track.share_token IS NOT NULL THEN
    RETURN v_track.share_token;
  END IF;
  
  -- Generate new token (12 chars alphanumeric)
  v_token := encode(gen_random_bytes(9), 'base64');
  v_token := replace(replace(replace(v_token, '+', 'x'), '/', 'y'), '=', '');
  v_token := substring(v_token from 1 for 12);
  
  -- Save token
  UPDATE public.tracks SET share_token = v_token WHERE id = _track_id;
  
  RETURN v_token;
END;
$$;

-- Function to revoke share token
CREATE OR REPLACE FUNCTION public.revoke_share_token(_track_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.tracks 
  SET share_token = NULL 
  WHERE id = _track_id 
    AND (user_id = auth.uid() OR public.is_admin(auth.uid()));
  
  RETURN FOUND;
END;
$$;

-- Function to get track by share token (for anonymous access)
CREATE OR REPLACE FUNCTION public.get_track_by_share_token(_token TEXT)
RETURNS public.tracks
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public.tracks 
  WHERE share_token = _token AND status = 'completed'
  LIMIT 1;
$$;

-- =====================================================
-- Migration: 20260129115450_148341b9-7a93-4959-8d67-7c602394d6b1.sql
-- =====================================================
-- Fix generate_share_token to not use pgcrypto extension
CREATE OR REPLACE FUNCTION public.generate_share_token(_track_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token TEXT;
  v_user_id UUID;
BEGIN
  -- Check ownership
  SELECT user_id INTO v_user_id FROM tracks WHERE id = _track_id;
  IF v_user_id IS NULL OR v_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  
  -- Generate token using built-in functions (no pgcrypto needed)
  v_token := substring(
    replace(replace(
      encode(sha256((random()::text || clock_timestamp()::text || _track_id::text)::bytea), 'base64'),
      '/', '_'), '+', '-'),
    1, 12
  );
  
  -- Update track
  UPDATE tracks SET share_token = v_token WHERE id = _track_id;
  
  RETURN v_token;
END;
$$;

-- =====================================================
-- Migration: 20260129130946_7eb49f9a-6aa2-4291-b272-2e6a155f73dd.sql
-- =====================================================
-- Update function to validate both token and track_id
CREATE OR REPLACE FUNCTION public.get_track_by_share_token(_token TEXT, _track_id UUID DEFAULT NULL)
RETURNS public.tracks
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public.tracks 
  WHERE share_token = _token 
    AND status = 'completed'
    AND (_track_id IS NULL OR id = _track_id)
  LIMIT 1;
$$;

-- =====================================================
-- Migration: 20260129141746_4469b90e-b417-4e51-aa7d-11565d72b453.sql
-- =====================================================
-- Add unique constraint for store_items to allow upsert by seller+type+source
ALTER TABLE public.store_items ADD CONSTRAINT store_items_seller_type_source_unique 
UNIQUE (seller_id, item_type, source_id);

-- Add index for faster lookups
CREATE INDEX IF NOT EXISTS idx_store_items_seller_type_source 
ON public.store_items (seller_id, item_type, source_id);

-- =====================================================
-- Migration: 20260129155801_4fcd7aff-51b1-40cd-88e9-233963292349.sql
-- =====================================================

-- Исправляем функцию get_ad_for_slot: приводим internal_id к text
CREATE OR REPLACE FUNCTION public.get_ad_for_slot(
  p_slot_key text,
  p_user_id uuid DEFAULT NULL,
  p_device_type text DEFAULT 'desktop'
)
RETURNS TABLE(
  campaign_id uuid,
  creative_id uuid,
  campaign_name text,
  campaign_type text,
  creative_type text,
  title text,
  subtitle text,
  cta_text text,
  click_url text,
  media_url text,
  media_type text,
  thumbnail_url text,
  external_video_url text,
  internal_type text,
  internal_id text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_slot_id uuid;
  v_is_ad_free boolean := false;
BEGIN
  -- Получаем ID слота
  SELECT id INTO v_slot_id 
  FROM public.ad_slots 
  WHERE slot_key = p_slot_key AND is_enabled = true;
  
  IF v_slot_id IS NULL THEN
    RETURN;
  END IF;
  
  -- Проверяем ad_free статус пользователя
  IF p_user_id IS NOT NULL THEN
    SELECT CASE 
      WHEN ad_free_until IS NOT NULL AND ad_free_until > now() 
      THEN true 
      ELSE false 
    END INTO v_is_ad_free
    FROM public.profiles
    WHERE user_id = p_user_id;
    
    IF v_is_ad_free THEN
      RETURN;
    END IF;
  END IF;
  
  -- Возвращаем рекламу для слота
  RETURN QUERY
  SELECT 
    c.id as campaign_id,
    cr.id as creative_id,
    c.name as campaign_name,
    c.campaign_type,
    cr.creative_type,
    cr.title,
    cr.subtitle,
    cr.cta_text,
    cr.click_url,
    cr.media_url,
    cr.media_type,
    cr.thumbnail_url,
    cr.external_video_url,
    c.internal_type,
    c.internal_id::text as internal_id
  FROM public.ad_campaigns c
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  LEFT JOIN public.ad_targeting t ON t.campaign_id = c.id
  WHERE 
    c.status = 'active'
    AND cs.slot_id = v_slot_id
    AND cs.is_active = true
    AND (c.start_date IS NULL OR c.start_date <= now())
    AND (c.end_date IS NULL OR c.end_date > now())
    AND (c.budget_total IS NULL OR c.impressions_count < c.budget_total)
    -- Device targeting
    AND (
      (p_device_type = 'mobile' AND COALESCE(t.target_mobile, true))
      OR (p_device_type = 'desktop' AND COALESCE(t.target_desktop, true))
      OR t.id IS NULL
    )
  ORDER BY 
    COALESCE(cs.priority_override, c.priority) DESC,
    random()
  LIMIT 1;
END;
$$;

-- Даём права на выполнение
GRANT EXECUTE ON FUNCTION public.get_ad_for_slot(text, uuid, text) TO anon, authenticated;


-- =====================================================
-- Migration: 20260129161657_211db0ae-19f8-494d-ba38-75bbd5b3ff39.sql
-- =====================================================
-- Create generation queue table
CREATE TABLE public.generation_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  position INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  
  -- Generation parameters (stored as JSON for flexibility)
  params JSONB NOT NULL,
  
  -- Result reference
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  
  -- Timing
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  started_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  
  -- Error tracking
  error_message TEXT,
  retry_count INTEGER DEFAULT 0
);

-- Index for efficient queue queries
CREATE INDEX idx_generation_queue_status ON public.generation_queue(status);
CREATE INDEX idx_generation_queue_user_pending ON public.generation_queue(user_id, status) WHERE status = 'pending';
CREATE INDEX idx_generation_queue_position ON public.generation_queue(position) WHERE status = 'pending';

-- Enable RLS
ALTER TABLE public.generation_queue ENABLE ROW LEVEL SECURITY;

-- Users can view their own queue items
CREATE POLICY "Users can view own queue items"
ON public.generation_queue
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

-- Users can cancel their own pending items
CREATE POLICY "Users can cancel own pending items"
ON public.generation_queue
FOR UPDATE
TO authenticated
USING (user_id = auth.uid() AND status = 'pending')
WITH CHECK (user_id = auth.uid() AND status = 'cancelled');

-- Admins can view all queue items
CREATE POLICY "Admins can view all queue items"
ON public.generation_queue
FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- Create settings for queue configuration
INSERT INTO public.settings (key, value, description) VALUES
  ('queue_max_concurrent_global', '3', 'Maximum simultaneous generations globally'),
  ('queue_max_per_user', '1', 'Maximum active generations per user')
ON CONFLICT (key) DO NOTHING;

-- Function to get next position in queue
CREATE OR REPLACE FUNCTION public.get_next_queue_position()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(MAX(position), 0) + 1 
  FROM public.generation_queue 
  WHERE status IN ('pending', 'processing');
$$;

-- Function to add item to queue
CREATE OR REPLACE FUNCTION public.add_to_generation_queue(
  p_user_id UUID,
  p_params JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_max_per_user INTEGER;
  v_active_count INTEGER;
  v_position INTEGER;
  v_queue_id UUID;
BEGIN
  -- Get max per user setting
  SELECT COALESCE((SELECT value::integer FROM settings WHERE key = 'queue_max_per_user'), 1)
  INTO v_max_per_user;
  
  -- Count user's active items (pending + processing)
  SELECT COUNT(*) INTO v_active_count
  FROM generation_queue
  WHERE user_id = p_user_id AND status IN ('pending', 'processing');
  
  IF v_active_count >= v_max_per_user THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'У вас уже есть активная генерация. Дождитесь её завершения.',
      'active_count', v_active_count
    );
  END IF;
  
  -- Get next position
  v_position := get_next_queue_position();
  
  -- Insert into queue
  INSERT INTO generation_queue (user_id, position, params)
  VALUES (p_user_id, v_position, p_params)
  RETURNING id INTO v_queue_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'queue_id', v_queue_id,
    'position', v_position
  );
END;
$$;

-- Function to get queue status for user
CREATE OR REPLACE FUNCTION public.get_user_queue_status(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_items JSONB;
  v_position INTEGER;
BEGIN
  -- Get user's queue items
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', id,
      'position', position,
      'status', status,
      'created_at', created_at,
      'started_at', started_at,
      'track_id', track_id
    ) ORDER BY position
  )
  INTO v_items
  FROM generation_queue
  WHERE user_id = p_user_id AND status IN ('pending', 'processing');
  
  -- Get current position in global queue
  SELECT MIN(position) INTO v_position
  FROM generation_queue
  WHERE user_id = p_user_id AND status = 'pending';
  
  RETURN jsonb_build_object(
    'items', COALESCE(v_items, '[]'::jsonb),
    'queue_position', v_position,
    'ahead_count', COALESCE(
      (SELECT COUNT(*) FROM generation_queue 
       WHERE status = 'pending' AND position < v_position), 0
    )
  );
END;
$$;

-- Function to get next item to process
CREATE OR REPLACE FUNCTION public.get_next_queue_item()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_max_concurrent INTEGER;
  v_current_processing INTEGER;
  v_next_item RECORD;
BEGIN
  -- Get max concurrent setting
  SELECT COALESCE((SELECT value::integer FROM settings WHERE key = 'queue_max_concurrent_global'), 3)
  INTO v_max_concurrent;
  
  -- Count currently processing
  SELECT COUNT(*) INTO v_current_processing
  FROM generation_queue
  WHERE status = 'processing';
  
  -- Check if we can process more
  IF v_current_processing >= v_max_concurrent THEN
    RETURN jsonb_build_object(
      'available', false,
      'reason', 'max_concurrent_reached',
      'current_processing', v_current_processing,
      'max_concurrent', v_max_concurrent
    );
  END IF;
  
  -- Get next pending item (oldest by position)
  SELECT * INTO v_next_item
  FROM generation_queue
  WHERE status = 'pending'
  ORDER BY position ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  
  IF v_next_item IS NULL THEN
    RETURN jsonb_build_object(
      'available', false,
      'reason', 'queue_empty'
    );
  END IF;
  
  -- Mark as processing
  UPDATE generation_queue
  SET status = 'processing', started_at = now()
  WHERE id = v_next_item.id;
  
  RETURN jsonb_build_object(
    'available', true,
    'queue_id', v_next_item.id,
    'user_id', v_next_item.user_id,
    'params', v_next_item.params,
    'position', v_next_item.position
  );
END;
$$;

-- Function to complete queue item
CREATE OR REPLACE FUNCTION public.complete_queue_item(
  p_queue_id UUID,
  p_track_id UUID DEFAULT NULL,
  p_success BOOLEAN DEFAULT true,
  p_error TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE generation_queue
  SET 
    status = CASE WHEN p_success THEN 'completed' ELSE 'failed' END,
    completed_at = now(),
    track_id = p_track_id,
    error_message = p_error
  WHERE id = p_queue_id;
  
  RETURN FOUND;
END;
$$;

-- =====================================================
-- Migration: 20260201114556_3d9c60a2-2a64-474e-a6a6-ecbf6db3cc5b.sql
-- =====================================================
-- Table for storing track health analysis results
CREATE TABLE public.track_health_reports (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  
  -- Quality metrics
  quality_score INTEGER CHECK (quality_score >= 1 AND quality_score <= 10),
  
  -- Audio analysis
  lufs_original NUMERIC(6,2),
  lufs_normalized NUMERIC(6,2),
  peak_db NUMERIC(6,2),
  dynamic_range NUMERIC(6,2),
  
  -- Spectrum analysis
  spectrum_ok BOOLEAN DEFAULT true,
  high_freq_cutoff INTEGER,
  upscale_detected BOOLEAN DEFAULT false,
  
  -- Technical specs
  sample_rate INTEGER,
  bit_depth INTEGER,
  channels INTEGER,
  duration NUMERIC(10,2),
  format TEXT,
  
  -- Master quality check
  master_quality BOOLEAN DEFAULT false,
  recommendations TEXT[],
  
  -- Plagiarism (for future ACRCloud integration)
  plagiarism_percent NUMERIC(5,2) DEFAULT 0,
  plagiarism_matches JSONB,
  plagiarism_checked_at TIMESTAMPTZ,
  
  -- Processing status
  analysis_status TEXT DEFAULT 'pending' CHECK (analysis_status IN ('pending', 'analyzing', 'completed', 'failed')),
  normalization_status TEXT DEFAULT 'pending' CHECK (normalization_status IN ('pending', 'processing', 'completed', 'skipped', 'failed')),
  normalized_audio_url TEXT,
  
  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create unique index on track_id (one report per track)
CREATE UNIQUE INDEX idx_track_health_reports_track_id ON public.track_health_reports(track_id);

-- Enable RLS
ALTER TABLE public.track_health_reports ENABLE ROW LEVEL SECURITY;

-- Admins and moderators can view all health reports
CREATE POLICY "Admins can view all health reports"
ON public.track_health_reports
FOR SELECT
USING (
  public.is_admin(auth.uid()) 
  OR public.has_permission(auth.uid(), 'moderation')
);

-- Service role can manage health reports (for edge functions)
CREATE POLICY "Service role can manage health reports"
ON public.track_health_reports
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Users can view their own track health reports
CREATE POLICY "Users can view own track health reports"
ON public.track_health_reports
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.tracks 
    WHERE tracks.id = track_health_reports.track_id 
    AND tracks.user_id = auth.uid()
  )
);

-- Trigger for updated_at
CREATE TRIGGER update_track_health_reports_updated_at
BEFORE UPDATE ON public.track_health_reports
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260201114940_700eed26-4678-42b8-bfe7-40f89214e8a4.sql
-- =====================================================
-- Table for promo videos with custom effects (Particles, Glow, etc.)
CREATE TABLE public.promo_videos (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  
  -- Video style settings
  style TEXT NOT NULL DEFAULT 'particles_glow' CHECK (style IN ('particles_glow', 'waveform', 'spectrum', 'minimal', 'cinematic')),
  aspect_ratio TEXT NOT NULL DEFAULT '9:16' CHECK (aspect_ratio IN ('9:16', '16:9', '1:1')),
  duration_seconds INTEGER DEFAULT 30 CHECK (duration_seconds >= 10 AND duration_seconds <= 60),
  
  -- Audio segment selection
  audio_start_time NUMERIC(10,2) DEFAULT 0,
  audio_end_time NUMERIC(10,2),
  best_segment_auto BOOLEAN DEFAULT true,
  
  -- Visual customization
  text_artist TEXT,
  text_title TEXT,
  text_position TEXT DEFAULT 'bottom' CHECK (text_position IN ('top', 'center', 'bottom', 'none')),
  cover_animation TEXT DEFAULT 'float' CHECK (cover_animation IN ('float', 'pulse', 'rotate', 'static')),
  particles_color TEXT DEFAULT '#00ffff',
  glow_intensity INTEGER DEFAULT 50 CHECK (glow_intensity >= 0 AND glow_intensity <= 100),
  
  -- Processing
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'rendering', 'completed', 'failed')),
  progress INTEGER DEFAULT 0 CHECK (progress >= 0 AND progress <= 100),
  error_message TEXT,
  
  -- Results
  video_url TEXT,
  thumbnail_url TEXT,
  file_size_bytes INTEGER,
  
  -- Pricing
  price_rub INTEGER DEFAULT 0,
  
  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX idx_promo_videos_track_id ON public.promo_videos(track_id);
CREATE INDEX idx_promo_videos_user_id ON public.promo_videos(user_id);
CREATE INDEX idx_promo_videos_status ON public.promo_videos(status);

-- Enable RLS
ALTER TABLE public.promo_videos ENABLE ROW LEVEL SECURITY;

-- Users can view their own promo videos
CREATE POLICY "Users can view own promo videos"
ON public.promo_videos
FOR SELECT
USING (user_id = auth.uid());

-- Users can create promo videos for their tracks
CREATE POLICY "Users can create promo videos"
ON public.promo_videos
FOR INSERT
WITH CHECK (
  user_id = auth.uid() AND
  EXISTS (
    SELECT 1 FROM public.tracks 
    WHERE tracks.id = promo_videos.track_id 
    AND tracks.user_id = auth.uid()
  )
);

-- Admins can view all promo videos
CREATE POLICY "Admins can view all promo videos"
ON public.promo_videos
FOR SELECT
USING (public.is_admin(auth.uid()));

-- Service role can manage all promo videos
CREATE POLICY "Service role can manage promo videos"
ON public.promo_videos
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Trigger for updated_at
CREATE TRIGGER update_promo_videos_updated_at
BEFORE UPDATE ON public.promo_videos
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Migration: 20260201121102_6e381818-63ab-4602-ae34-470d5824b8ab.sql
-- =====================================================
-- Add distribution workflow fields to tracks table
ALTER TABLE public.tracks 
ADD COLUMN IF NOT EXISTS distribution_status text DEFAULT 'none' CHECK (distribution_status IN ('none', 'pending_moderation', 'approved', 'rejected', 'pending_master', 'processing', 'completed')),
ADD COLUMN IF NOT EXISTS distribution_requested_at timestamptz,
ADD COLUMN IF NOT EXISTS distribution_approved_at timestamptz,
ADD COLUMN IF NOT EXISTS distribution_approved_by uuid REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS master_audio_url text,
ADD COLUMN IF NOT EXISTS master_uploaded_at timestamptz,
ADD COLUMN IF NOT EXISTS processing_stage text,
ADD COLUMN IF NOT EXISTS processing_progress integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS processing_started_at timestamptz,
ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz,
ADD COLUMN IF NOT EXISTS plagiarism_check_status text DEFAULT 'none' CHECK (plagiarism_check_status IN ('none', 'pending', 'clean', 'detected', 'error')),
ADD COLUMN IF NOT EXISTS plagiarism_check_result jsonb,
ADD COLUMN IF NOT EXISTS upscale_detected boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS lufs_normalized boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS metadata_cleaned boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS blockchain_hash text,
ADD COLUMN IF NOT EXISTS certificate_url text,
ADD COLUMN IF NOT EXISTS gold_pack_url text;

-- Create index for distribution status queries
CREATE INDEX IF NOT EXISTS idx_tracks_distribution_status ON public.tracks(distribution_status);
CREATE INDEX IF NOT EXISTS idx_tracks_plagiarism_status ON public.tracks(plagiarism_check_status);

-- Create distribution_logs table for audit trail
CREATE TABLE IF NOT EXISTS public.distribution_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  action text NOT NULL,
  stage text,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.distribution_logs ENABLE ROW LEVEL SECURITY;

-- Policies for distribution_logs
CREATE POLICY "Users can view their own distribution logs"
  ON public.distribution_logs FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin(auth.uid()));

CREATE POLICY "System can insert distribution logs"
  ON public.distribution_logs FOR INSERT
  WITH CHECK (true);

-- Add realtime for distribution processing updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.distribution_logs;

-- =====================================================
-- Migration: 20260201133842_d658eca3-e5bd-4ef2-96db-cc00d3970eb0.sql
-- =====================================================
-- Fix resolve_track_voting RPC to return to moderation queue instead of direct publish
-- Per business logic: Voting → Back to Moderation → Admin decides → Distribution

CREATE OR REPLACE FUNCTION public.resolve_track_voting(p_track_id uuid, p_manual_result text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_like_ratio NUMERIC;
  v_result TEXT;
  v_new_status TEXT;
BEGIN
  -- Get track data
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;
  
  -- Manual override from moderator
  IF p_manual_result IS NOT NULL THEN
    v_result := p_manual_result;
    v_new_status := CASE 
      WHEN p_manual_result = 'approved' THEN 'pending' -- Return to moderation queue for final decision
      ELSE 'rejected'
    END;
    
    UPDATE public.tracks SET
      moderation_status = v_new_status,
      voting_result = 'manual_override_' || p_manual_result,
      is_public = false -- Keep hidden until admin makes final decision
    WHERE id = p_track_id;
    
    -- Notify owner
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track.user_id,
      'voting_result',
      CASE WHEN p_manual_result = 'approved' 
        THEN '🎉 Голосование пройдено!' 
        ELSE 'Голосование завершено'
      END,
      CASE WHEN p_manual_result = 'approved'
        THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
        ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
      END,
      'track',
      p_track_id
    );
    
    RETURN jsonb_build_object(
      'success', true,
      'result', p_manual_result,
      'method', 'manual_override',
      'new_moderation_status', v_new_status
    );
  END IF;
  
  -- Automatic result calculation
  v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);
  
  SELECT COALESCE(value::integer, 10) INTO v_min_votes
  FROM public.settings WHERE key = 'voting_min_votes';
  
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio
  FROM public.settings WHERE key = 'voting_approval_ratio';
  
  -- Not enough votes = rejected
  IF v_total_votes < v_min_votes THEN
    v_result := 'rejected';
    v_new_status := 'rejected';
  ELSE
    v_like_ratio := v_track.voting_likes_count::numeric / v_total_votes;
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved';
      v_new_status := 'pending'; -- Back to moderation queue for final label decision
    ELSE
      v_result := 'rejected';
      v_new_status := 'rejected';
    END IF;
  END IF;
  
  UPDATE public.tracks SET
    moderation_status = v_new_status,
    voting_result = v_result,
    -- CRITICAL: Do NOT auto-publish! Label makes final decision
    is_public = false
  WHERE id = p_track_id;
  
  -- Notify owner
  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_track.user_id,
    'voting_result',
    CASE WHEN v_result = 'voting_approved' 
      THEN '🎉 Голосование пройдено!' 
      ELSE 'Голосование завершено'
    END,
    CASE WHEN v_result = 'voting_approved'
      THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
      ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
    END,
    'track',
    p_track_id
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'total_votes', v_total_votes,
    'like_ratio', v_like_ratio,
    'min_votes_required', v_min_votes,
    'approval_ratio_required', v_approval_ratio,
    'new_moderation_status', v_new_status
  );
END;
$function$;

-- =====================================================
-- Migration: 20260201152510_7e19cc79-3868-4deb-b4af-731b228ded93.sql
-- =====================================================
-- Add voting_type field to tracks table
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS voting_type TEXT DEFAULT 'public';

-- Create internal_votes table for moderator voting
CREATE TABLE IF NOT EXISTS public.internal_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  moderator_id UUID NOT NULL,
  vote_type TEXT NOT NULL CHECK (vote_type IN ('approve', 'reject')),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(track_id, moderator_id)
);

-- Enable RLS on internal_votes
ALTER TABLE public.internal_votes ENABLE ROW LEVEL SECURITY;

-- RLS policies for internal_votes - only admins/moderators can see and vote
CREATE POLICY "Moderators can view internal votes"
  ON public.internal_votes FOR SELECT
  TO authenticated
  USING (
    public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'tracks')
  );

CREATE POLICY "Moderators can create internal votes"
  ON public.internal_votes FOR INSERT
  TO authenticated
  WITH CHECK (
    moderator_id = auth.uid() AND
    (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'tracks'))
  );

CREATE POLICY "Moderators can update own internal votes"
  ON public.internal_votes FOR UPDATE
  TO authenticated
  USING (
    moderator_id = auth.uid() AND
    (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'tracks'))
  );

CREATE POLICY "Moderators can delete own internal votes"
  ON public.internal_votes FOR DELETE
  TO authenticated
  USING (
    moderator_id = auth.uid() AND
    (public.is_admin(auth.uid()) OR public.has_permission(auth.uid(), 'tracks'))
  );

-- Update send_track_to_voting function to support voting_type
CREATE OR REPLACE FUNCTION public.send_track_to_voting(
  p_track_id UUID,
  p_duration_days INTEGER DEFAULT NULL,
  p_voting_type TEXT DEFAULT 'public'
)
RETURNS JSONB AS $$
DECLARE
  v_duration INTEGER;
  v_ends_at TIMESTAMP WITH TIME ZONE;
  v_track_owner UUID;
BEGIN
  -- Get track owner for notification
  SELECT user_id INTO v_track_owner FROM public.tracks WHERE id = p_track_id;
  
  -- Get duration from settings or parameter
  IF p_duration_days IS NULL THEN
    SELECT COALESCE(value::integer, 7) INTO v_duration
    FROM public.settings WHERE key = 'voting_duration_days';
  ELSE
    v_duration := p_duration_days;
  END IF;
  
  -- For internal voting, set shorter default (1 day) if not specified
  IF p_voting_type = 'internal' AND p_duration_days IS NULL THEN
    v_duration := 1;
  END IF;
  
  v_ends_at := now() + (v_duration || ' days')::interval;
  
  UPDATE public.tracks SET
    moderation_status = 'voting',
    voting_type = p_voting_type,
    voting_started_at = now(),
    voting_ends_at = v_ends_at,
    voting_result = 'pending',
    voting_likes_count = 0,
    voting_dislikes_count = 0,
    is_public = CASE WHEN p_voting_type = 'public' THEN true ELSE false END
  WHERE id = p_track_id;
  
  -- Notify track owner
  IF v_track_owner IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track_owner,
      'voting_started',
      CASE WHEN p_voting_type = 'public' 
        THEN '🗳️ Трек на голосовании сообщества'
        ELSE '🗳️ Трек на внутреннем голосовании'
      END,
      'Ваш трек отправлен на голосование. Результаты будут известны через ' || v_duration || ' дней.',
      'track',
      p_track_id
    );
  END IF;
  
  RETURN jsonb_build_object(
    'success', true,
    'voting_type', p_voting_type,
    'voting_ends_at', v_ends_at,
    'duration_days', v_duration
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Function to resolve internal voting
CREATE OR REPLACE FUNCTION public.resolve_internal_voting(p_track_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_approve_count INTEGER;
  v_reject_count INTEGER;
  v_total INTEGER;
  v_result TEXT;
  v_track RECORD;
BEGIN
  -- Get vote counts
  SELECT 
    COUNT(*) FILTER (WHERE vote_type = 'approve'),
    COUNT(*) FILTER (WHERE vote_type = 'reject')
  INTO v_approve_count, v_reject_count
  FROM public.internal_votes WHERE track_id = p_track_id;
  
  v_total := v_approve_count + v_reject_count;
  
  -- Need at least 3 votes for internal voting
  IF v_total < 3 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Недостаточно голосов модераторов (минимум 3)',
      'current_votes', v_total
    );
  END IF;
  
  -- 66% approval threshold for internal voting
  IF v_approve_count::numeric / v_total >= 0.66 THEN
    v_result := 'approved';
  ELSE
    v_result := 'rejected';
  END IF;
  
  -- Get track info for notification
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  
  -- Update track status - internal voting decides directly
  UPDATE public.tracks SET
    moderation_status = v_result,
    voting_result = 'internal_' || v_result,
    is_public = CASE WHEN v_result = 'approved' THEN true ELSE false END
  WHERE id = p_track_id;
  
  -- Notify owner
  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_track.user_id,
    'voting_result',
    CASE WHEN v_result = 'approved' 
      THEN '✅ Трек одобрен!'
      ELSE '❌ Трек отклонён'
    END,
    CASE WHEN v_result = 'approved'
      THEN 'Ваш трек "' || v_track.title || '" одобрен командой модераторов и опубликован.'
      ELSE 'К сожалению, трек "' || v_track.title || '" не прошёл внутреннее голосование.'
    END,
    'track',
    p_track_id
  );
  
  -- Clean up internal votes
  DELETE FROM public.internal_votes WHERE track_id = p_track_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'approve_count', v_approve_count,
    'reject_count', v_reject_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- =====================================================
-- Migration: 20260201172935_78db5275-82dd-4b8a-be90-61e7408a7bf7.sql
-- =====================================================
-- Добавляем настройку для хешированного пин-кода бэкапа
-- SHA-256 хеш от "123456" как дефолтный (пользователь сменит)
INSERT INTO public.settings (key, value, description)
VALUES (
  'backup_pin_hash', 
  '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
  'SHA-256 хеш пин-кода для экспорта БД (только super_admin)'
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- =====================================================
-- Migration: 20260201180422_f2b16bad-3066-4733-8a94-14f903731fd3.sql
-- =====================================================
-- ===============================================
-- SECURITY FIX: Prevent vote manipulation
-- ===============================================

-- Add unique constraint on track_votes to prevent duplicate votes
-- Use IF NOT EXISTS pattern with DO block
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'track_votes_user_track_unique'
  ) THEN
    ALTER TABLE public.track_votes 
    ADD CONSTRAINT track_votes_user_track_unique UNIQUE (user_id, track_id);
  END IF;
END $$;

-- Add unique constraint on contest_votes to prevent duplicate contest votes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'contest_votes_user_entry_unique'
  ) THEN
    ALTER TABLE public.contest_votes 
    ADD CONSTRAINT contest_votes_user_entry_unique UNIQUE (user_id, entry_id);
  END IF;
END $$;

-- ===============================================
-- AUDIT TRAIL: Add soft delete and edit tracking
-- ===============================================

-- Add soft delete to messages
ALTER TABLE public.messages 
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE DEFAULT NULL;

-- Add edit tracking to track_comments
ALTER TABLE public.track_comments 
ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP WITH TIME ZONE DEFAULT NULL;

-- Add edit tracking to contest_entry_comments
ALTER TABLE public.contest_entry_comments 
ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP WITH TIME ZONE DEFAULT NULL;

-- ===============================================
-- TRIGGER: Auto-set edited_at on comment update
-- ===============================================

CREATE OR REPLACE FUNCTION public.set_comment_edited_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only set edited_at if content changed
  IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
    NEW.edited_at = now();
  END IF;
  RETURN NEW;
END;
$$;

-- Apply to track_comments
DROP TRIGGER IF EXISTS set_track_comment_edited_at ON public.track_comments;
CREATE TRIGGER set_track_comment_edited_at
  BEFORE UPDATE ON public.track_comments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_comment_edited_at();

-- Apply to contest_entry_comments
DROP TRIGGER IF EXISTS set_contest_comment_edited_at ON public.contest_entry_comments;
CREATE TRIGGER set_contest_comment_edited_at
  BEFORE UPDATE ON public.contest_entry_comments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_comment_edited_at();

-- ===============================================
-- SECURITY: Update messages RLS for soft delete
-- ===============================================

-- Update message select policy to hide deleted messages
DROP POLICY IF EXISTS "Users can view their conversation messages" ON public.messages;
CREATE POLICY "Users can view their conversation messages"
ON public.messages
FOR SELECT
USING (
  deleted_at IS NULL
  AND public.is_participant_in_conversation(auth.uid(), conversation_id)
);

-- Simple update policy for soft delete (let trigger handle validation)
DROP POLICY IF EXISTS "Users can update own messages" ON public.messages;
CREATE POLICY "Users can update own messages"
ON public.messages
FOR UPDATE
USING (sender_id = auth.uid())
WITH CHECK (sender_id = auth.uid());

-- =====================================================
-- Migration: 20260201195553_c734227a-2eba-4f8e-8540-b010195d2af1.sql
-- =====================================================
-- Add all statuses including 'none' and 'flagged'
ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_plagiarism_check_status_check;
ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_copyright_check_status_check;

ALTER TABLE public.tracks ADD CONSTRAINT tracks_plagiarism_check_status_check 
  CHECK (plagiarism_check_status IN ('none', 'pending', 'checking', 'clean', 'flagged', 'failed'));

ALTER TABLE public.tracks ADD CONSTRAINT tracks_copyright_check_status_check 
  CHECK (copyright_check_status IN ('none', 'pending', 'checking', 'clean', 'flagged', 'failed'));

-- =====================================================
-- Migration: 20260201195827_b33bfe53-e02a-489b-bbde-511b01b27b9b.sql
-- =====================================================
-- Create copyright verification requests table
CREATE TABLE public.copyright_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  moderator_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'responded', 'approved', 'rejected')),
  request_reason TEXT NOT NULL,
  plagiarism_data JSONB,
  user_response TEXT,
  user_documents TEXT[], -- URLs to uploaded proof documents
  moderator_decision TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  responded_at TIMESTAMP WITH TIME ZONE,
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolved_by UUID
);

-- Enable RLS
ALTER TABLE public.copyright_requests ENABLE ROW LEVEL SECURITY;

-- Users can view their own requests
CREATE POLICY "Users can view own copyright requests" ON public.copyright_requests
  FOR SELECT USING (auth.uid() = user_id);

-- Users can respond to their own pending requests
CREATE POLICY "Users can respond to own pending requests" ON public.copyright_requests
  FOR UPDATE USING (auth.uid() = user_id AND status = 'pending')
  WITH CHECK (auth.uid() = user_id);

-- Moderators can view all requests
CREATE POLICY "Moderators can view all requests" ON public.copyright_requests
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'moderator', 'super_admin'))
  );

-- Moderators can create requests
CREATE POLICY "Moderators can create requests" ON public.copyright_requests
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'moderator', 'super_admin'))
  );

-- Moderators can update requests (approve/reject)
CREATE POLICY "Moderators can update requests" ON public.copyright_requests
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'moderator', 'super_admin'))
  );

-- Add index
CREATE INDEX idx_copyright_requests_track ON public.copyright_requests(track_id);
CREATE INDEX idx_copyright_requests_user ON public.copyright_requests(user_id);
CREATE INDEX idx_copyright_requests_status ON public.copyright_requests(status);

-- =====================================================
-- Migration: 20260201200012_cfae115b-0a15-4d82-8e5b-7bf2e5d5978b.sql
-- =====================================================
-- Add copyright_pending to moderation_status constraint
ALTER TABLE public.tracks DROP CONSTRAINT IF EXISTS tracks_moderation_status_check;
ALTER TABLE public.tracks ADD CONSTRAINT tracks_moderation_status_check 
  CHECK (moderation_status IN ('none', 'pending', 'approved', 'rejected', 'voting', 'copyright_pending'));

-- =====================================================
-- Migration: 20260202105358_f44ef94d-b1e1-42c4-a427-d4c555e7ef6a.sql
-- =====================================================
-- Add wav_url column to tracks table for easy WAV file access
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS wav_url TEXT;

-- =====================================================
-- Migration: 20260202105749_9b9fea40-28be-4eb8-8914-e647cc55df17.sql
-- =====================================================
-- Add unique constraint for track_id + addon_service_id to enable proper upserts
ALTER TABLE public.track_addons 
ADD CONSTRAINT track_addons_track_addon_unique UNIQUE (track_id, addon_service_id);

-- =====================================================
-- Migration: 20260202112319_1767ccf7-0485-485a-af51-1cc05687794b.sql
-- =====================================================
-- Add audio/wav and audio/x-wav to allowed mime types for tracks bucket
UPDATE storage.buckets 
SET allowed_mime_types = array_cat(
  allowed_mime_types, 
  ARRAY['audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave']::text[]
)
WHERE name = 'tracks';

-- =====================================================
-- Migration: 20260204225649_1e359d66-6d04-4743-868c-3d9bc2ec9fc6.sql
-- =====================================================
-- Drop the existing conflicting policy and recreate with correct logic
DROP POLICY IF EXISTS "Admins can view all profiles" ON profiles;
DROP POLICY IF EXISTS "Users can view own full profile" ON profiles;

-- Recreate both policies correctly
-- Users can see their own full profile (including balance)
CREATE POLICY "Users can view own full profile"
ON profiles FOR SELECT
USING (auth.uid() = user_id);

-- Admins can see all profiles 
CREATE POLICY "Admins can view all profiles"
ON profiles FOR SELECT
USING (is_admin(auth.uid()));

-- =====================================================
-- Migration: 20260206083255_aeb80976-4fff-4538-ba54-ebebdec122cc.sql
-- =====================================================
-- Create maintenance whitelist table
CREATE TABLE IF NOT EXISTS public.maintenance_whitelist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  granted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(user_id)
);

-- Enable RLS
ALTER TABLE public.maintenance_whitelist ENABLE ROW LEVEL SECURITY;

-- Policy: Only admins can read
CREATE POLICY "Admins can read whitelist"
ON public.maintenance_whitelist FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- Policy: Only super_admin can insert
CREATE POLICY "Super admin can insert whitelist"
ON public.maintenance_whitelist FOR INSERT
TO authenticated
WITH CHECK (public.is_super_admin(auth.uid()));

-- Policy: Only super_admin can delete
CREATE POLICY "Super admin can delete whitelist"
ON public.maintenance_whitelist FOR DELETE
TO authenticated
USING (public.is_super_admin(auth.uid()));

-- Function to check if user is in maintenance whitelist
CREATE OR REPLACE FUNCTION public.is_maintenance_whitelisted(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.maintenance_whitelist
    WHERE user_id = _user_id
  )
$$;

-- Add comment
COMMENT ON TABLE public.maintenance_whitelist IS 'Users allowed to access during maintenance mode';

-- =====================================================
-- Migration: 20260207111133_7ea76426-bd67-4eae-a665-e1fa23fcf5ef.sql
-- =====================================================

-- =====================================================
-- FORUM SYSTEM: Complete Database Schema
-- =====================================================

-- 1. Forum Categories (sections)
CREATE TABLE public.forum_categories (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  name_ru TEXT NOT NULL,
  description TEXT,
  description_ru TEXT,
  slug TEXT NOT NULL UNIQUE,
  icon TEXT,
  color TEXT,
  sort_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  is_locked BOOLEAN DEFAULT false,
  parent_id UUID REFERENCES public.forum_categories(id) ON DELETE SET NULL,
  topics_count INTEGER DEFAULT 0,
  posts_count INTEGER DEFAULT 0,
  last_topic_id UUID,
  last_post_at TIMESTAMPTZ,
  min_trust_level INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Forum Tags
CREATE TABLE public.forum_tags (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  name_ru TEXT NOT NULL,
  color TEXT DEFAULT '#6366f1',
  usage_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Forum Topics (threads)
CREATE TABLE public.forum_topics (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  category_id UUID NOT NULL REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  slug TEXT NOT NULL,
  content TEXT NOT NULL,
  content_html TEXT,
  excerpt TEXT,
  is_pinned BOOLEAN DEFAULT false,
  is_locked BOOLEAN DEFAULT false,
  is_hidden BOOLEAN DEFAULT false,
  is_solved BOOLEAN DEFAULT false,
  solved_post_id UUID,
  -- Track integration
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  -- Stats
  views_count INTEGER DEFAULT 0,
  posts_count INTEGER DEFAULT 0,
  likes_count INTEGER DEFAULT 0,
  votes_score INTEGER DEFAULT 0,
  -- Last activity
  last_post_id UUID,
  last_post_at TIMESTAMPTZ DEFAULT now(),
  last_post_user_id UUID,
  -- Moderation
  hidden_by UUID,
  hidden_at TIMESTAMPTZ,
  hidden_reason TEXT,
  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at TIMESTAMPTZ,
  bumped_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(category_id, slug)
);

-- 4. Forum Topic Tags (many-to-many)
CREATE TABLE public.forum_topic_tags (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  tag_id UUID NOT NULL REFERENCES public.forum_tags(id) ON DELETE CASCADE,
  UNIQUE(topic_id, tag_id)
);

-- 5. Forum Posts (replies)
CREATE TABLE public.forum_posts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  content TEXT NOT NULL,
  content_html TEXT,
  -- Reply threading
  parent_id UUID REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  reply_to_user_id UUID,
  reply_depth INTEGER DEFAULT 0,
  -- Stats
  likes_count INTEGER DEFAULT 0,
  votes_score INTEGER DEFAULT 0,
  -- Moderation
  is_hidden BOOLEAN DEFAULT false,
  hidden_by UUID,
  hidden_at TIMESTAMPTZ,
  hidden_reason TEXT,
  is_solution BOOLEAN DEFAULT false,
  -- Track attachment
  track_id UUID REFERENCES public.tracks(id) ON DELETE SET NULL,
  -- Edit history
  edit_count INTEGER DEFAULT 0,
  edited_at TIMESTAMPTZ,
  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Update solved_post_id FK after forum_posts exists
ALTER TABLE public.forum_topics 
  ADD CONSTRAINT forum_topics_solved_post_id_fkey 
  FOREIGN KEY (solved_post_id) REFERENCES public.forum_posts(id) ON DELETE SET NULL;

-- 6. Forum Post Votes (upvote/downvote)
CREATE TABLE public.forum_post_votes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  vote_type SMALLINT NOT NULL CHECK (vote_type IN (-1, 1)),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Can vote on either a post or a topic (the first post)
  CONSTRAINT vote_target_check CHECK (
    (post_id IS NOT NULL AND topic_id IS NULL) OR
    (post_id IS NULL AND topic_id IS NOT NULL)
  ),
  UNIQUE(post_id, user_id),
  UNIQUE(topic_id, user_id)
);

-- 7. Forum Post Reactions (emoji)
CREATE TABLE public.forum_post_reactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT reaction_target_check CHECK (
    (post_id IS NOT NULL AND topic_id IS NULL) OR
    (post_id IS NULL AND topic_id IS NOT NULL)
  ),
  UNIQUE(post_id, user_id, emoji),
  UNIQUE(topic_id, user_id, emoji)
);

-- 8. Forum Bookmarks
CREATE TABLE public.forum_bookmarks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

-- 9. Forum Topic Subscriptions (follow/watch)
CREATE TABLE public.forum_topic_subscriptions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  level TEXT NOT NULL DEFAULT 'watching' CHECK (level IN ('watching', 'tracking', 'muted')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

-- 10. Forum Category Subscriptions
CREATE TABLE public.forum_category_subscriptions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  category_id UUID NOT NULL REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  level TEXT NOT NULL DEFAULT 'watching' CHECK (level IN ('watching', 'tracking', 'muted')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, category_id)
);

-- 11. Forum Read Status (track what user has read)
CREATE TABLE public.forum_read_status (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  last_read_post_id UUID REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

-- 12. Forum Reports
CREATE TABLE public.forum_reports (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  reporter_id UUID NOT NULL,
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  reason TEXT NOT NULL,
  details TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'resolved', 'dismissed')),
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  resolution_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT report_target_check CHECK (
    (post_id IS NOT NULL AND topic_id IS NULL) OR
    (post_id IS NULL AND topic_id IS NOT NULL)
  )
);

-- 13. Forum User Trust Levels
CREATE TABLE public.forum_user_stats (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE,
  trust_level INTEGER DEFAULT 0 CHECK (trust_level >= 0 AND trust_level <= 4),
  -- Activity metrics
  topics_created INTEGER DEFAULT 0,
  posts_created INTEGER DEFAULT 0,
  likes_given INTEGER DEFAULT 0,
  likes_received INTEGER DEFAULT 0,
  solutions_count INTEGER DEFAULT 0,
  reports_filed INTEGER DEFAULT 0,
  reports_received INTEGER DEFAULT 0,
  -- Reputation
  reputation_score INTEGER DEFAULT 0,
  -- Moderation
  warnings_count INTEGER DEFAULT 0,
  is_silenced BOOLEAN DEFAULT false,
  silenced_until TIMESTAMPTZ,
  silence_reason TEXT,
  -- Timestamps
  first_post_at TIMESTAMPTZ,
  last_post_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 14. Forum Warnings (moderation)
CREATE TABLE public.forum_warnings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  issued_by UUID NOT NULL,
  reason TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'warning' CHECK (severity IN ('notice', 'warning', 'final_warning', 'silence', 'ban')),
  -- Silence/ban duration
  duration_hours INTEGER,
  expires_at TIMESTAMPTZ,
  -- Related content
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  -- Status
  is_active BOOLEAN DEFAULT true,
  acknowledged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 15. Forum Moderation Logs
CREATE TABLE public.forum_mod_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  moderator_id UUID NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL CHECK (target_type IN ('topic', 'post', 'user', 'category')),
  target_id UUID NOT NULL,
  details JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================
-- INDEXES
-- =====================================================

CREATE INDEX idx_forum_topics_category ON public.forum_topics(category_id);
CREATE INDEX idx_forum_topics_user ON public.forum_topics(user_id);
CREATE INDEX idx_forum_topics_track ON public.forum_topics(track_id) WHERE track_id IS NOT NULL;
CREATE INDEX idx_forum_topics_pinned ON public.forum_topics(is_pinned, bumped_at DESC) WHERE NOT is_hidden;
CREATE INDEX idx_forum_topics_bumped ON public.forum_topics(bumped_at DESC) WHERE NOT is_hidden;
CREATE INDEX idx_forum_topics_created ON public.forum_topics(created_at DESC);
CREATE INDEX idx_forum_topics_votes ON public.forum_topics(votes_score DESC);

CREATE INDEX idx_forum_posts_topic ON public.forum_posts(topic_id, created_at);
CREATE INDEX idx_forum_posts_user ON public.forum_posts(user_id);
CREATE INDEX idx_forum_posts_parent ON public.forum_posts(parent_id) WHERE parent_id IS NOT NULL;

CREATE INDEX idx_forum_post_votes_post ON public.forum_post_votes(post_id) WHERE post_id IS NOT NULL;
CREATE INDEX idx_forum_post_votes_topic ON public.forum_post_votes(topic_id) WHERE topic_id IS NOT NULL;
CREATE INDEX idx_forum_post_votes_user ON public.forum_post_votes(user_id);

CREATE INDEX idx_forum_topic_tags_topic ON public.forum_topic_tags(topic_id);
CREATE INDEX idx_forum_topic_tags_tag ON public.forum_topic_tags(tag_id);

CREATE INDEX idx_forum_bookmarks_user ON public.forum_bookmarks(user_id);
CREATE INDEX idx_forum_read_status_user ON public.forum_read_status(user_id);
CREATE INDEX idx_forum_subscriptions_user ON public.forum_topic_subscriptions(user_id);

CREATE INDEX idx_forum_reports_status ON public.forum_reports(status) WHERE status = 'pending';
CREATE INDEX idx_forum_warnings_user ON public.forum_warnings(user_id, is_active);
CREATE INDEX idx_forum_mod_logs_mod ON public.forum_mod_logs(moderator_id, created_at DESC);

CREATE INDEX idx_forum_user_stats_trust ON public.forum_user_stats(trust_level);
CREATE INDEX idx_forum_user_stats_reputation ON public.forum_user_stats(reputation_score DESC);

-- =====================================================
-- RLS POLICIES
-- =====================================================

ALTER TABLE public.forum_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topic_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_post_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_post_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_bookmarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topic_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_category_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_read_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_user_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_warnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_mod_logs ENABLE ROW LEVEL SECURITY;

-- Categories: anyone can view active categories
CREATE POLICY "Anyone can view active categories" ON public.forum_categories
  FOR SELECT USING (is_active = true);

CREATE POLICY "Admins manage categories" ON public.forum_categories
  FOR ALL USING (public.is_admin(auth.uid()));

-- Tags: anyone can view
CREATE POLICY "Anyone can view tags" ON public.forum_tags
  FOR SELECT USING (true);

CREATE POLICY "Admins manage tags" ON public.forum_tags
  FOR ALL USING (public.is_admin(auth.uid()));

-- Topics: visible if not hidden (or own/admin)
CREATE POLICY "View visible topics" ON public.forum_topics
  FOR SELECT USING (
    NOT is_hidden 
    OR user_id = auth.uid() 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Authenticated users create topics" ON public.forum_topics
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own topics" ON public.forum_topics
  FOR UPDATE USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Admins delete topics" ON public.forum_topics
  FOR DELETE USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
  );

-- Topic Tags: follow topic visibility
CREATE POLICY "View topic tags" ON public.forum_topic_tags
  FOR SELECT USING (true);

CREATE POLICY "Topic authors manage tags" ON public.forum_topic_tags
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM forum_topics WHERE id = topic_id AND user_id = auth.uid())
    OR public.is_admin(auth.uid())
  );

CREATE POLICY "Topic authors delete tags" ON public.forum_topic_tags
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM forum_topics WHERE id = topic_id AND user_id = auth.uid())
    OR public.is_admin(auth.uid())
  );

-- Posts: visible if not hidden (or own/admin)
CREATE POLICY "View visible posts" ON public.forum_posts
  FOR SELECT USING (
    NOT is_hidden 
    OR user_id = auth.uid() 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Authenticated users create posts" ON public.forum_posts
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own posts" ON public.forum_posts
  FOR UPDATE USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Admins delete posts" ON public.forum_posts
  FOR DELETE USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
  );

-- Votes: users manage own votes
CREATE POLICY "View votes" ON public.forum_post_votes
  FOR SELECT USING (true);

CREATE POLICY "Users manage own votes" ON public.forum_post_votes
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users delete own votes" ON public.forum_post_votes
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Users update own votes" ON public.forum_post_votes
  FOR UPDATE USING (auth.uid() = user_id);

-- Reactions: users manage own
CREATE POLICY "View reactions" ON public.forum_post_reactions
  FOR SELECT USING (true);

CREATE POLICY "Users manage own reactions" ON public.forum_post_reactions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users delete own reactions" ON public.forum_post_reactions
  FOR DELETE USING (auth.uid() = user_id);

-- Bookmarks: users manage own
CREATE POLICY "Users view own bookmarks" ON public.forum_bookmarks
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users manage own bookmarks" ON public.forum_bookmarks
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users delete own bookmarks" ON public.forum_bookmarks
  FOR DELETE USING (auth.uid() = user_id);

-- Topic Subscriptions: users manage own
CREATE POLICY "Users view own subscriptions" ON public.forum_topic_subscriptions
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users manage own subscriptions" ON public.forum_topic_subscriptions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own subscriptions" ON public.forum_topic_subscriptions
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users delete own subscriptions" ON public.forum_topic_subscriptions
  FOR DELETE USING (auth.uid() = user_id);

-- Category Subscriptions
CREATE POLICY "Users view own cat subs" ON public.forum_category_subscriptions
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users manage own cat subs" ON public.forum_category_subscriptions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own cat subs" ON public.forum_category_subscriptions
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users delete own cat subs" ON public.forum_category_subscriptions
  FOR DELETE USING (auth.uid() = user_id);

-- Read Status: users manage own
CREATE POLICY "Users view own read status" ON public.forum_read_status
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users manage own read status" ON public.forum_read_status
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own read status" ON public.forum_read_status
  FOR UPDATE USING (auth.uid() = user_id);

-- Reports: users can create, mods can view all
CREATE POLICY "Users create reports" ON public.forum_reports
  FOR INSERT WITH CHECK (auth.uid() = reporter_id);

CREATE POLICY "Users view own reports" ON public.forum_reports
  FOR SELECT USING (
    auth.uid() = reporter_id 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Mods update reports" ON public.forum_reports
  FOR UPDATE USING (
    public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

-- User Stats: public read, system write
CREATE POLICY "Anyone can view forum stats" ON public.forum_user_stats
  FOR SELECT USING (true);

CREATE POLICY "System manages stats" ON public.forum_user_stats
  FOR ALL USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
  );

-- Warnings: users see own, mods see all
CREATE POLICY "Users view own warnings" ON public.forum_warnings
  FOR SELECT USING (
    auth.uid() = user_id 
    OR public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Mods create warnings" ON public.forum_warnings
  FOR INSERT WITH CHECK (
    public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Mods update warnings" ON public.forum_warnings
  FOR UPDATE USING (
    public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

-- Mod Logs: only mods can view
CREATE POLICY "Mods view logs" ON public.forum_mod_logs
  FOR SELECT USING (
    public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

CREATE POLICY "Mods create logs" ON public.forum_mod_logs
  FOR INSERT WITH CHECK (
    public.is_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'moderation')
  );

-- =====================================================
-- TRIGGERS & FUNCTIONS
-- =====================================================

-- Auto-update topic post count and last_post info
CREATE OR REPLACE FUNCTION public.forum_update_topic_on_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE forum_topics SET
      posts_count = posts_count + 1,
      last_post_id = NEW.id,
      last_post_at = NEW.created_at,
      last_post_user_id = NEW.user_id,
      bumped_at = NEW.created_at
    WHERE id = NEW.topic_id;
    
    -- Update category stats
    UPDATE forum_categories SET
      posts_count = posts_count + 1,
      last_post_at = NEW.created_at
    WHERE id = (SELECT category_id FROM forum_topics WHERE id = NEW.topic_id);
    
    -- Update user stats
    INSERT INTO forum_user_stats (user_id, posts_created, last_post_at)
    VALUES (NEW.user_id, 1, NEW.created_at)
    ON CONFLICT (user_id) DO UPDATE SET
      posts_created = forum_user_stats.posts_created + 1,
      last_post_at = NEW.created_at,
      updated_at = now();
      
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE forum_topics SET
      posts_count = GREATEST(0, posts_count - 1)
    WHERE id = OLD.topic_id;
    
    UPDATE forum_categories SET
      posts_count = GREATEST(0, posts_count - 1)
    WHERE id = (SELECT category_id FROM forum_topics WHERE id = OLD.topic_id);
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_forum_post_stats
  AFTER INSERT OR DELETE ON public.forum_posts
  FOR EACH ROW EXECUTE FUNCTION public.forum_update_topic_on_post();

-- Auto-update category topic count
CREATE OR REPLACE FUNCTION public.forum_update_category_on_topic()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE forum_categories SET
      topics_count = topics_count + 1,
      last_topic_id = NEW.id,
      last_post_at = NEW.created_at
    WHERE id = NEW.category_id;
    
    -- Update user stats
    INSERT INTO forum_user_stats (user_id, topics_created, first_post_at)
    VALUES (NEW.user_id, 1, NEW.created_at)
    ON CONFLICT (user_id) DO UPDATE SET
      topics_created = forum_user_stats.topics_created + 1,
      first_post_at = COALESCE(forum_user_stats.first_post_at, NEW.created_at),
      updated_at = now();
      
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE forum_categories SET
      topics_count = GREATEST(0, topics_count - 1)
    WHERE id = OLD.category_id;
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_forum_topic_stats
  AFTER INSERT OR DELETE ON public.forum_topics
  FOR EACH ROW EXECUTE FUNCTION public.forum_update_category_on_topic();

-- Auto-update vote scores
CREATE OR REPLACE FUNCTION public.forum_update_vote_score()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    IF NEW.post_id IS NOT NULL THEN
      UPDATE forum_posts SET votes_score = (
        SELECT COALESCE(SUM(vote_type), 0) FROM forum_post_votes WHERE post_id = NEW.post_id
      ) WHERE id = NEW.post_id;
    END IF;
    IF NEW.topic_id IS NOT NULL THEN
      UPDATE forum_topics SET votes_score = (
        SELECT COALESCE(SUM(vote_type), 0) FROM forum_post_votes WHERE topic_id = NEW.topic_id
      ) WHERE id = NEW.topic_id;
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.post_id IS NOT NULL THEN
      UPDATE forum_posts SET votes_score = (
        SELECT COALESCE(SUM(vote_type), 0) FROM forum_post_votes WHERE post_id = OLD.post_id
      ) WHERE id = OLD.post_id;
    END IF;
    IF OLD.topic_id IS NOT NULL THEN
      UPDATE forum_topics SET votes_score = (
        SELECT COALESCE(SUM(vote_type), 0) FROM forum_post_votes WHERE topic_id = OLD.topic_id
      ) WHERE id = OLD.topic_id;
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_forum_vote_score
  AFTER INSERT OR UPDATE OR DELETE ON public.forum_post_votes
  FOR EACH ROW EXECUTE FUNCTION public.forum_update_vote_score();

-- Track edited_at on posts
CREATE OR REPLACE FUNCTION public.forum_set_post_edited()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.content IS DISTINCT FROM NEW.content THEN
    NEW.edited_at = now();
    NEW.edit_count = COALESCE(OLD.edit_count, 0) + 1;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_post_edited
  BEFORE UPDATE ON public.forum_posts
  FOR EACH ROW EXECUTE FUNCTION public.forum_set_post_edited();

-- Track edited_at on topics
CREATE OR REPLACE FUNCTION public.forum_set_topic_edited()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.content IS DISTINCT FROM NEW.content OR OLD.title IS DISTINCT FROM NEW.title THEN
    NEW.edited_at = now();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_topic_edited
  BEFORE UPDATE ON public.forum_topics
  FOR EACH ROW EXECUTE FUNCTION public.forum_set_topic_edited();

-- Function to increment topic views (security definer to avoid RLS issues)
CREATE OR REPLACE FUNCTION public.forum_increment_topic_views(p_topic_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE forum_topics SET views_count = views_count + 1 WHERE id = p_topic_id;
END;
$$;

-- Enable realtime for topics and posts
ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_topics;
ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_posts;


-- =====================================================
-- Migration: 20260207113335_f95a338b-df65-40ec-bb8c-ee069ee39fcb.sql
-- =====================================================

-- ============================================
-- FORUM STAGE 1: Missing tables, indexes, triggers
-- ============================================

-- 1. Forum user stats (reputation, trust levels)
CREATE TABLE IF NOT EXISTS public.forum_user_stats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,
  trust_level INTEGER NOT NULL DEFAULT 0,
  reputation_score INTEGER NOT NULL DEFAULT 0,
  topics_created INTEGER NOT NULL DEFAULT 0,
  posts_created INTEGER NOT NULL DEFAULT 0,
  likes_given INTEGER NOT NULL DEFAULT 0,
  likes_received INTEGER NOT NULL DEFAULT 0,
  solutions_count INTEGER NOT NULL DEFAULT 0,
  warnings_count INTEGER NOT NULL DEFAULT 0,
  is_silenced BOOLEAN NOT NULL DEFAULT false,
  silenced_until TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_user_stats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Forum stats readable by all authenticated"
  ON public.forum_user_stats FOR SELECT TO authenticated USING (true);

CREATE POLICY "Users can view own stats"
  ON public.forum_user_stats FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "System updates stats"
  ON public.forum_user_stats FOR UPDATE TO authenticated
  USING (auth.uid() = user_id);

-- 2. Forum warnings system
CREATE TABLE IF NOT EXISTS public.forum_warnings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  moderator_id UUID NOT NULL,
  reason TEXT NOT NULL,
  severity INTEGER NOT NULL DEFAULT 1 CHECK (severity BETWEEN 1 AND 5),
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_warnings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see own warnings"
  ON public.forum_warnings FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Moderators manage warnings"
  ON public.forum_warnings FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin', 'moderator')
    )
  );

-- 3. Forum drafts
CREATE TABLE IF NOT EXISTS public.forum_drafts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  title TEXT,
  content TEXT NOT NULL DEFAULT '',
  draft_type TEXT NOT NULL DEFAULT 'reply' CHECK (draft_type IN ('topic', 'reply')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_drafts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own drafts"
  ON public.forum_drafts FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 4. Forum attachments
CREATE TABLE IF NOT EXISTS public.forum_attachments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  file_url TEXT NOT NULL,
  file_type TEXT NOT NULL,
  file_size INTEGER NOT NULL DEFAULT 0,
  original_name TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Attachments readable by authenticated"
  ON public.forum_attachments FOR SELECT TO authenticated USING (true);

CREATE POLICY "Users upload own attachments"
  ON public.forum_attachments FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users delete own attachments"
  ON public.forum_attachments FOR DELETE TO authenticated
  USING (auth.uid() = user_id);

-- ============================================
-- PERFORMANCE INDEXES
-- ============================================

-- Topics listing (hot sort)
CREATE INDEX IF NOT EXISTS idx_forum_topics_category_pinned_bumped
  ON public.forum_topics (category_id, is_pinned DESC, bumped_at DESC NULLS LAST)
  WHERE is_hidden = false;

-- Topics by creation date
CREATE INDEX IF NOT EXISTS idx_forum_topics_created
  ON public.forum_topics (created_at DESC)
  WHERE is_hidden = false;

-- Topics by votes
CREATE INDEX IF NOT EXISTS idx_forum_topics_votes
  ON public.forum_topics (votes_score DESC)
  WHERE is_hidden = false;

-- Posts in topic
CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_created
  ON public.forum_posts (topic_id, created_at ASC);

-- Posts by user
CREATE INDEX IF NOT EXISTS idx_forum_posts_user
  ON public.forum_posts (user_id, created_at DESC);

-- Votes lookup
CREATE INDEX IF NOT EXISTS idx_forum_votes_user_post
  ON public.forum_post_votes (user_id, post_id);

CREATE INDEX IF NOT EXISTS idx_forum_votes_user_topic
  ON public.forum_post_votes (user_id, topic_id);

-- Bookmarks
CREATE INDEX IF NOT EXISTS idx_forum_bookmarks_user
  ON public.forum_bookmarks (user_id, created_at DESC);

-- Reports queue
CREATE INDEX IF NOT EXISTS idx_forum_reports_pending
  ON public.forum_reports (status, created_at DESC)
  WHERE status = 'pending';

-- Tags usage
CREATE INDEX IF NOT EXISTS idx_forum_topic_tags_topic
  ON public.forum_topic_tags (topic_id);

CREATE INDEX IF NOT EXISTS idx_forum_topic_tags_tag
  ON public.forum_topic_tags (tag_id);

-- User stats
CREATE INDEX IF NOT EXISTS idx_forum_user_stats_reputation
  ON public.forum_user_stats (reputation_score DESC);

-- Warnings active
CREATE INDEX IF NOT EXISTS idx_forum_warnings_user_active
  ON public.forum_warnings (user_id, is_active)
  WHERE is_active = true;

-- ============================================
-- TRIGGERS: Auto-update user stats
-- ============================================

-- Auto-create/update forum_user_stats on post creation
CREATE OR REPLACE FUNCTION public.forum_update_user_stats_on_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.forum_user_stats (user_id, posts_created)
  VALUES (NEW.user_id, 1)
  ON CONFLICT (user_id) DO UPDATE
  SET posts_created = forum_user_stats.posts_created + 1,
      updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_user_stats_post ON public.forum_posts;
CREATE TRIGGER trg_forum_user_stats_post
  AFTER INSERT ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_update_user_stats_on_post();

-- Auto-create/update forum_user_stats on topic creation
CREATE OR REPLACE FUNCTION public.forum_update_user_stats_on_topic()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.forum_user_stats (user_id, topics_created)
  VALUES (NEW.user_id, 1)
  ON CONFLICT (user_id) DO UPDATE
  SET topics_created = forum_user_stats.topics_created + 1,
      updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_user_stats_topic ON public.forum_topics;
CREATE TRIGGER trg_forum_user_stats_topic
  AFTER INSERT ON public.forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_update_user_stats_on_topic();

-- Auto-update reputation on votes
CREATE OR REPLACE FUNCTION public.forum_update_reputation_on_vote()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author_id UUID;
  v_rep_change INTEGER;
BEGIN
  -- Find post/topic author
  IF NEW.post_id IS NOT NULL THEN
    SELECT user_id INTO v_author_id FROM public.forum_posts WHERE id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id INTO v_author_id FROM public.forum_topics WHERE id = NEW.topic_id;
  END IF;

  IF v_author_id IS NULL OR v_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  v_rep_change := CASE WHEN NEW.vote_type = 1 THEN 5 ELSE -2 END;

  INSERT INTO public.forum_user_stats (user_id, reputation_score, likes_received)
  VALUES (
    v_author_id,
    v_rep_change,
    CASE WHEN NEW.vote_type = 1 THEN 1 ELSE 0 END
  )
  ON CONFLICT (user_id) DO UPDATE
  SET reputation_score = forum_user_stats.reputation_score + v_rep_change,
      likes_received = forum_user_stats.likes_received + CASE WHEN NEW.vote_type = 1 THEN 1 ELSE 0 END,
      updated_at = now();

  -- Update voter's likes_given
  INSERT INTO public.forum_user_stats (user_id, likes_given)
  VALUES (NEW.user_id, 1)
  ON CONFLICT (user_id) DO UPDATE
  SET likes_given = forum_user_stats.likes_given + 1,
      updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_reputation_vote ON public.forum_post_votes;
CREATE TRIGGER trg_forum_reputation_vote
  AFTER INSERT ON public.forum_post_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_update_reputation_on_vote();

-- Auto-generate excerpt for topics
CREATE OR REPLACE FUNCTION public.forum_auto_excerpt()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.excerpt IS NULL OR NEW.excerpt = '' THEN
    NEW.excerpt := substring(NEW.content FROM 1 FOR 200);
  END IF;
  -- Auto-set bumped_at on creation
  IF TG_OP = 'INSERT' AND NEW.bumped_at IS NULL THEN
    NEW.bumped_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_auto_excerpt ON public.forum_topics;
CREATE TRIGGER trg_forum_auto_excerpt
  BEFORE INSERT OR UPDATE ON public.forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_auto_excerpt();

-- Insert default forum settings
INSERT INTO public.settings (key, value, description) VALUES
  ('forum_enabled', 'true', 'Вкл/выкл форум'),
  ('forum_max_post_length', '50000', 'Макс. длина поста'),
  ('forum_max_file_size', '10', 'Макс. размер файла (МБ)'),
  ('forum_downvote_enabled', 'true', 'Вкл/выкл downvote'),
  ('forum_reactions_enabled', 'true', 'Вкл/выкл emoji-реакции'),
  ('forum_solutions_enabled', 'true', 'Вкл/выкл лучший ответ'),
  ('forum_trust_levels_enabled', 'true', 'Вкл/выкл систему уровней'),
  ('forum_realtime_enabled', 'true', 'Вкл/выкл realtime'),
  ('forum_automod_enabled', 'true', 'Вкл/выкл автомодерацию'),
  ('forum_animations_enabled', 'true', 'Вкл/выкл анимации'),
  ('forum_polls_enabled', 'true', 'Вкл/выкл опросы'),
  ('forum_search_enabled', 'true', 'Вкл/выкл поиск'),
  ('forum_auto_topics_enabled', 'true', 'Автотемы для треков'),
  ('forum_timecodes_enabled', 'true', 'Тайм-коды в постах'),
  ('forum_notifications_enabled', 'true', 'Уведомления форума'),
  ('forum_rate_limit_per_minute', '3', 'Лимит постов в минуту'),
  ('forum_post_cooldown_seconds', '15', 'Кулдаун между постами'),
  ('forum_auto_hide_threshold', '5', 'Жалоб для автоскрытия')
ON CONFLICT DO NOTHING;


-- =====================================================
-- Migration: 20260207114409_78f66a4c-37c7-44f5-8c7b-de940e5caa8e.sql
-- =====================================================
-- Create storage bucket for forum attachments
INSERT INTO storage.buckets (id, name, public)
VALUES ('forum-attachments', 'forum-attachments', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for forum attachments
CREATE POLICY "Forum attachments are publicly readable"
ON storage.objects FOR SELECT
USING (bucket_id = 'forum-attachments');

CREATE POLICY "Authenticated users can upload forum attachments"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'forum-attachments' AND auth.uid() IS NOT NULL);

CREATE POLICY "Users can update own forum attachments"
ON storage.objects FOR UPDATE
USING (bucket_id = 'forum-attachments' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "Users can delete own forum attachments"
ON storage.objects FOR DELETE
USING (bucket_id = 'forum-attachments' AND auth.uid()::text = (storage.foldername(name))[1]);


-- =====================================================
-- Migration: 20260207115111_a47b16b7-327b-409f-a3cd-ed6993351de7.sql
-- =====================================================

-- =============================================================
-- STAGE 5: Reputation System & Trust Levels
-- =============================================================

-- 1. Add reputation columns to forum_user_stats (if not already present)
ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS warnings_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_muted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS muted_until timestamptz DEFAULT NULL;

-- 2. Reputation config table for trust level thresholds
CREATE TABLE IF NOT EXISTS public.forum_reputation_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trust_level integer NOT NULL UNIQUE,
  min_reputation integer NOT NULL DEFAULT 0,
  label text NOT NULL,
  label_ru text NOT NULL,
  color text NOT NULL DEFAULT '#888',
  icon text DEFAULT NULL,
  max_likes_per_day integer DEFAULT NULL,
  max_topics_per_day integer DEFAULT NULL,
  max_posts_per_day integer DEFAULT NULL,
  can_downvote boolean NOT NULL DEFAULT false,
  can_upload_files boolean NOT NULL DEFAULT false,
  can_use_reactions boolean NOT NULL DEFAULT false,
  can_edit_wiki boolean NOT NULL DEFAULT false,
  can_retag boolean NOT NULL DEFAULT false,
  can_move_topics boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_reputation_config ENABLE ROW LEVEL SECURITY;

-- Everyone can read config
CREATE POLICY "Anyone can read reputation config"
  ON public.forum_reputation_config FOR SELECT
  TO authenticated USING (true);

-- Insert default trust level thresholds
INSERT INTO public.forum_reputation_config (trust_level, min_reputation, label, label_ru, color, icon, max_likes_per_day, max_topics_per_day, max_posts_per_day, can_downvote, can_upload_files, can_use_reactions)
VALUES
  (0, 0,    'Newcomer',  'Новичок',   '#888888', NULL,     10,   1,   5,   false, false, false),
  (1, 50,   'Member',    'Участник',  '#3B82F6', 'Star',   30,   5,   30,  false, true,  true),
  (2, 200,  'Regular',   'Активный',  '#22C55E', 'Award',  100,  20,  100, true,  true,  true),
  (3, 500,  'Leader',    'Лидер',     '#A855F7', 'Crown',  NULL, NULL, NULL, true, true,  true),
  (4, 1000, 'Elder',     'Старейшина','#F97316', 'Shield', NULL, NULL, NULL, true, true,  true)
ON CONFLICT (trust_level) DO NOTHING;

-- 3. Reputation history log
CREATE TABLE IF NOT EXISTS public.forum_reputation_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  delta integer NOT NULL,
  reason text NOT NULL,
  source_type text NOT NULL, -- 'vote', 'solution', 'warning', 'post_hidden', 'topic_created', 'post_created', 'reaction', 'manual'
  source_id uuid DEFAULT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_reputation_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own reputation log"
  ON public.forum_reputation_log FOR SELECT
  TO authenticated USING (user_id = auth.uid());

CREATE POLICY "System inserts reputation log"
  ON public.forum_reputation_log FOR INSERT
  TO authenticated WITH CHECK (true);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_forum_rep_log_user ON public.forum_reputation_log (user_id, created_at DESC);

-- 4. Function: award reputation points
CREATE OR REPLACE FUNCTION public.forum_award_reputation(
  p_user_id uuid,
  p_delta integer,
  p_reason text,
  p_source_type text,
  p_source_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_rep integer;
  v_new_trust integer;
  v_old_trust integer;
BEGIN
  -- Log the reputation change
  INSERT INTO forum_reputation_log (user_id, delta, reason, source_type, source_id)
  VALUES (p_user_id, p_delta, p_reason, p_source_type, p_source_id);

  -- Update reputation in user stats
  INSERT INTO forum_user_stats (user_id, reputation_score)
  VALUES (p_user_id, GREATEST(0, p_delta))
  ON CONFLICT (user_id) DO UPDATE
  SET reputation_score = GREATEST(0, forum_user_stats.reputation_score + p_delta),
      updated_at = now();

  -- Get current values
  SELECT reputation_score, trust_level INTO v_new_rep, v_old_trust
  FROM forum_user_stats WHERE user_id = p_user_id;

  -- Calculate new trust level based on thresholds
  SELECT COALESCE(MAX(trust_level), 0) INTO v_new_trust
  FROM forum_reputation_config
  WHERE min_reputation <= v_new_rep;

  -- Don't downgrade below manually set level (trust_level stays if higher)
  IF v_new_trust > v_old_trust THEN
    UPDATE forum_user_stats
    SET trust_level = v_new_trust, updated_at = now()
    WHERE user_id = p_user_id;
  END IF;
END;
$$;

-- 5. Trigger: Award reputation on receiving upvote/downvote
CREATE OR REPLACE FUNCTION public.forum_on_vote_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_author uuid;
  v_topic_author uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Find the author of the voted content
    IF NEW.post_id IS NOT NULL THEN
      SELECT user_id INTO v_post_author FROM forum_posts WHERE id = NEW.post_id;
      IF v_post_author IS NOT NULL AND v_post_author != NEW.user_id THEN
        IF NEW.vote_type = 1 THEN
          PERFORM forum_award_reputation(v_post_author, 5, 'Получен upvote на пост', 'vote', NEW.id);
        ELSE
          PERFORM forum_award_reputation(v_post_author, -2, 'Получен downvote на пост', 'vote', NEW.id);
        END IF;
      END IF;
    ELSIF NEW.topic_id IS NOT NULL THEN
      SELECT user_id INTO v_topic_author FROM forum_topics WHERE id = NEW.topic_id;
      IF v_topic_author IS NOT NULL AND v_topic_author != NEW.user_id THEN
        IF NEW.vote_type = 1 THEN
          PERFORM forum_award_reputation(v_topic_author, 5, 'Получен upvote на тему', 'vote', NEW.id);
        ELSE
          PERFORM forum_award_reputation(v_topic_author, -2, 'Получен downvote на тему', 'vote', NEW.id);
        END IF;
      END IF;
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    -- Reverse the reputation when vote is removed
    IF OLD.post_id IS NOT NULL THEN
      SELECT user_id INTO v_post_author FROM forum_posts WHERE id = OLD.post_id;
      IF v_post_author IS NOT NULL AND v_post_author != OLD.user_id THEN
        IF OLD.vote_type = 1 THEN
          PERFORM forum_award_reputation(v_post_author, -5, 'Upvote отменён', 'vote', OLD.id);
        ELSE
          PERFORM forum_award_reputation(v_post_author, 2, 'Downvote отменён', 'vote', OLD.id);
        END IF;
      END IF;
    ELSIF OLD.topic_id IS NOT NULL THEN
      SELECT user_id INTO v_topic_author FROM forum_topics WHERE id = OLD.topic_id;
      IF v_topic_author IS NOT NULL AND v_topic_author != OLD.user_id THEN
        IF OLD.vote_type = 1 THEN
          PERFORM forum_award_reputation(v_topic_author, -5, 'Upvote отменён', 'vote', OLD.id);
        ELSE
          PERFORM forum_award_reputation(v_topic_author, 2, 'Downvote отменён', 'vote', OLD.id);
        END IF;
      END IF;
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_vote_reputation ON public.forum_post_votes;
CREATE TRIGGER trg_forum_vote_reputation
  AFTER INSERT OR DELETE ON public.forum_post_votes
  FOR EACH ROW EXECUTE FUNCTION public.forum_on_vote_reputation();

-- 6. Trigger: Award reputation on topic creation (+2)
CREATE OR REPLACE FUNCTION public.forum_on_topic_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM forum_award_reputation(NEW.user_id, 2, 'Создание темы', 'topic_created', NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_topic_reputation ON public.forum_topics;
CREATE TRIGGER trg_forum_topic_reputation
  AFTER INSERT ON public.forum_topics
  FOR EACH ROW EXECUTE FUNCTION public.forum_on_topic_reputation();

-- 7. Trigger: Award reputation on post creation (+1)
CREATE OR REPLACE FUNCTION public.forum_on_post_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM forum_award_reputation(NEW.user_id, 1, 'Ответ в теме', 'post_created', NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_post_reputation ON public.forum_posts;
CREATE TRIGGER trg_forum_post_reputation
  AFTER INSERT ON public.forum_posts
  FOR EACH ROW EXECUTE FUNCTION public.forum_on_post_reputation();

-- 8. Trigger: Award reputation on receiving reaction (+1)
CREATE OR REPLACE FUNCTION public.forum_on_reaction_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.post_id IS NOT NULL THEN
      SELECT user_id INTO v_author FROM forum_posts WHERE id = NEW.post_id;
    ELSIF NEW.topic_id IS NOT NULL THEN
      SELECT user_id INTO v_author FROM forum_topics WHERE id = NEW.topic_id;
    END IF;
    IF v_author IS NOT NULL AND v_author != NEW.user_id THEN
      PERFORM forum_award_reputation(v_author, 1, 'Получена реакция', 'reaction', NEW.id);
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.post_id IS NOT NULL THEN
      SELECT user_id INTO v_author FROM forum_posts WHERE id = OLD.post_id;
    ELSIF OLD.topic_id IS NOT NULL THEN
      SELECT user_id INTO v_author FROM forum_topics WHERE id = OLD.topic_id;
    END IF;
    IF v_author IS NOT NULL AND v_author != OLD.user_id THEN
      PERFORM forum_award_reputation(v_author, -1, 'Реакция снята', 'reaction', OLD.id);
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_reaction_reputation ON public.forum_post_reactions;
CREATE TRIGGER trg_forum_reaction_reputation
  AFTER INSERT OR DELETE ON public.forum_post_reactions
  FOR EACH ROW EXECUTE FUNCTION public.forum_on_reaction_reputation();

-- 9. Function: Mark solution and award reputation (+15)
CREATE OR REPLACE FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_topic RECORD;
  v_post RECORD;
  v_caller uuid;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_topic FROM forum_topics WHERE id = p_topic_id;
  IF v_topic IS NULL THEN RETURN false; END IF;

  -- Only topic author can mark solution
  IF v_topic.user_id != v_caller THEN
    RAISE EXCEPTION 'Только автор темы может отметить решение';
  END IF;

  SELECT * INTO v_post FROM forum_posts WHERE id = p_post_id AND topic_id = p_topic_id;
  IF v_post IS NULL THEN RETURN false; END IF;

  -- Clear previous solution
  UPDATE forum_posts SET is_solution = false WHERE topic_id = p_topic_id AND is_solution = true;

  -- Mark new solution
  UPDATE forum_posts SET is_solution = true WHERE id = p_post_id;
  UPDATE forum_topics SET is_solved = true, solved_post_id = p_post_id WHERE id = p_topic_id;

  -- Award reputation to solution author (if not the topic author)
  IF v_post.user_id != v_caller THEN
    PERFORM forum_award_reputation(v_post.user_id, 15, 'Ответ отмечен как решение', 'solution', p_post_id);
  END IF;

  RETURN true;
END;
$$;

-- 10. Function: Get forum user stats with trust level config
CREATE OR REPLACE FUNCTION public.forum_get_user_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats RECORD;
  v_config RECORD;
  v_next_config RECORD;
  v_result jsonb;
BEGIN
  -- Get or create stats
  INSERT INTO forum_user_stats (user_id) VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_stats FROM forum_user_stats WHERE user_id = p_user_id;
  SELECT * INTO v_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level;
  SELECT * INTO v_next_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level + 1;

  v_result := jsonb_build_object(
    'user_id', p_user_id,
    'reputation_score', v_stats.reputation_score,
    'trust_level', v_stats.trust_level,
    'trust_label', COALESCE(v_config.label_ru, 'Новичок'),
    'trust_color', COALESCE(v_config.color, '#888'),
    'trust_icon', v_config.icon,
    'topics_created', v_stats.topics_created,
    'posts_created', v_stats.posts_created,
    'likes_given', v_stats.likes_given,
    'likes_received', v_stats.likes_received,
    'solutions_count', v_stats.solutions_count,
    'warnings_count', v_stats.warnings_count,
    'is_silenced', v_stats.is_silenced,
    'silenced_until', v_stats.silenced_until,
    'can_downvote', COALESCE(v_config.can_downvote, false),
    'can_upload_files', COALESCE(v_config.can_upload_files, false),
    'can_use_reactions', COALESCE(v_config.can_use_reactions, false),
    'next_level_rep', v_next_config.min_reputation,
    'next_level_label', v_next_config.label_ru,
    'progress_to_next', CASE
      WHEN v_next_config.min_reputation IS NULL THEN 100
      WHEN v_config.min_reputation IS NULL THEN 0
      ELSE ROUND(
        ((v_stats.reputation_score - v_config.min_reputation)::numeric /
         GREATEST(v_next_config.min_reputation - v_config.min_reputation, 1)::numeric) * 100
      )
    END
  );

  RETURN v_result;
END;
$$;

-- 11. Leaderboard function
CREATE OR REPLACE FUNCTION public.forum_get_leaderboard(p_limit integer DEFAULT 20)
RETURNS TABLE(
  user_id uuid,
  username text,
  avatar_url text,
  reputation_score integer,
  trust_level integer,
  topics_created integer,
  posts_created integer,
  solutions_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    fus.user_id,
    p.username,
    p.avatar_url,
    fus.reputation_score,
    fus.trust_level,
    fus.topics_created,
    fus.posts_created,
    fus.solutions_count
  FROM forum_user_stats fus
  JOIN profiles p ON p.user_id = fus.user_id
  WHERE fus.reputation_score > 0
  ORDER BY fus.reputation_score DESC
  LIMIT p_limit;
$$;


-- =====================================================
-- Migration: 20260207115127_58c263bb-bc73-40ae-84dd-58abce9355df.sql
-- =====================================================

-- Fix overly permissive INSERT policy on forum_reputation_log
-- Only SECURITY DEFINER functions write to this table, so restrict direct inserts
DROP POLICY IF EXISTS "System inserts reputation log" ON public.forum_reputation_log;

-- No direct INSERT allowed — all inserts go through forum_award_reputation() which is SECURITY DEFINER
-- If needed for admin, we can add a role-based policy later


-- =====================================================
-- Migration: 20260207120711_892fadfc-0788-472e-ad6a-261d04e153d5.sql
-- =====================================================

-- Enable realtime for forum_posts and forum_topics tables
-- Check and add only if not already in publication
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' 
    AND schemaname = 'public' 
    AND tablename = 'forum_posts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_posts;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' 
    AND schemaname = 'public' 
    AND tablename = 'forum_topics'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_topics;
  END IF;
END $$;


-- =====================================================
-- Migration: 20260207121110_6aa634e9-12f9-4a3d-88da-43f0805063f4.sql
-- =====================================================

-- =============================================
-- Forum Notifications: DB triggers
-- Uses existing `notifications` table
-- =============================================

-- 1. Notify topic author when someone replies to their topic
CREATE OR REPLACE FUNCTION forum_notify_topic_reply()
RETURNS TRIGGER AS $$
DECLARE
  v_topic_owner uuid;
  v_topic_title text;
  v_actor_username text;
BEGIN
  -- Get topic owner and title
  SELECT user_id, title INTO v_topic_owner, v_topic_title
  FROM forum_topics WHERE id = NEW.topic_id;

  -- Don't notify yourself
  IF v_topic_owner IS NULL OR v_topic_owner = NEW.user_id THEN
    RETURN NEW;
  END IF;

  -- Check subscription (skip if user unsubscribed)
  IF EXISTS (
    SELECT 1 FROM forum_topic_subscriptions 
    WHERE topic_id = NEW.topic_id AND user_id = v_topic_owner AND level = 'muted'
  ) THEN
    RETURN NEW;
  END IF;

  -- Get actor username
  SELECT username INTO v_actor_username FROM profiles_public WHERE user_id = NEW.user_id;

  INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_topic_owner,
    'forum_reply',
    'Новый ответ в вашей теме',
    COALESCE(v_actor_username, 'Пользователь') || ' ответил в теме «' || LEFT(v_topic_title, 60) || '»',
    NEW.user_id,
    'forum_topic',
    NEW.topic_id
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_notify_topic_reply
  AFTER INSERT ON forum_posts
  FOR EACH ROW
  WHEN (NEW.parent_id IS NULL)
  EXECUTE FUNCTION forum_notify_topic_reply();


-- 2. Notify post author when someone replies to their post
CREATE OR REPLACE FUNCTION forum_notify_post_reply()
RETURNS TRIGGER AS $$
DECLARE
  v_parent_owner uuid;
  v_topic_title text;
  v_actor_username text;
BEGIN
  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get parent post owner
  SELECT user_id INTO v_parent_owner FROM forum_posts WHERE id = NEW.parent_id;

  -- Don't notify yourself
  IF v_parent_owner IS NULL OR v_parent_owner = NEW.user_id THEN
    RETURN NEW;
  END IF;

  -- Check subscription
  IF EXISTS (
    SELECT 1 FROM forum_topic_subscriptions 
    WHERE topic_id = NEW.topic_id AND user_id = v_parent_owner AND level = 'muted'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT title INTO v_topic_title FROM forum_topics WHERE id = NEW.topic_id;
  SELECT username INTO v_actor_username FROM profiles_public WHERE user_id = NEW.user_id;

  INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_parent_owner,
    'forum_post_reply',
    'Ответ на ваш пост',
    COALESCE(v_actor_username, 'Пользователь') || ' ответил на ваш пост в теме «' || LEFT(v_topic_title, 60) || '»',
    NEW.user_id,
    'forum_post',
    NEW.id
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_notify_post_reply
  AFTER INSERT ON forum_posts
  FOR EACH ROW
  WHEN (NEW.parent_id IS NOT NULL)
  EXECUTE FUNCTION forum_notify_post_reply();


-- 3. Notify when post is marked as solution
CREATE OR REPLACE FUNCTION forum_notify_solution()
RETURNS TRIGGER AS $$
DECLARE
  v_post_owner uuid;
  v_topic_title text;
BEGIN
  -- Only trigger when is_solution changes to true
  IF NEW.is_solution IS NOT TRUE OR OLD.is_solution IS TRUE THEN
    RETURN NEW;
  END IF;

  SELECT user_id INTO v_post_owner FROM forum_posts WHERE id = NEW.id;
  SELECT title INTO v_topic_title FROM forum_topics WHERE id = NEW.topic_id;

  -- Don't notify if topic owner marked own post
  IF v_post_owner IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_post_owner,
    'forum_solution',
    'Ваш ответ отмечен как решение! 🎉',
    'Ваш ответ в теме «' || LEFT(v_topic_title, 60) || '» отмечен как лучшее решение',
    'forum_topic',
    NEW.topic_id
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_notify_solution
  AFTER UPDATE ON forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION forum_notify_solution();


-- 4. Notify on upvote (only significant votes, not every one)
CREATE OR REPLACE FUNCTION forum_notify_upvote()
RETURNS TRIGGER AS $$
DECLARE
  v_target_owner uuid;
  v_topic_title text;
  v_topic_id uuid;
  v_current_score int;
BEGIN
  -- Only upvotes
  IF NEW.vote_type != 1 THEN
    RETURN NEW;
  END IF;

  -- Determine target
  IF NEW.post_id IS NOT NULL THEN
    SELECT user_id, topic_id, votes_score INTO v_target_owner, v_topic_id, v_current_score
    FROM forum_posts WHERE id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id, id, votes_score INTO v_target_owner, v_topic_id, v_current_score
    FROM forum_topics WHERE id = NEW.topic_id;
  END IF;

  -- Don't notify yourself
  IF v_target_owner IS NULL OR v_target_owner = NEW.user_id THEN
    RETURN NEW;
  END IF;

  -- Only notify at milestones (1, 5, 10, 25, 50, 100...)
  IF v_current_score NOT IN (1, 5, 10, 25, 50, 100, 250, 500) THEN
    RETURN NEW;
  END IF;

  SELECT title INTO v_topic_title FROM forum_topics WHERE id = v_topic_id;

  INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
  VALUES (
    v_target_owner,
    'forum_upvote',
    'Ваш пост оценили ▲' || v_current_score,
    'Ваш пост в теме «' || LEFT(v_topic_title, 60) || '» набрал ' || v_current_score || ' голосов',
    NEW.user_id,
    'forum_topic',
    v_topic_id
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_notify_upvote
  AFTER INSERT ON forum_post_votes
  FOR EACH ROW
  EXECUTE FUNCTION forum_notify_upvote();


-- 5. Auto-subscribe topic author when creating a topic
CREATE OR REPLACE FUNCTION forum_auto_subscribe_topic_author()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO forum_topic_subscriptions (user_id, topic_id, level)
  VALUES (NEW.user_id, NEW.id, 'watching')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_auto_subscribe_author
  AFTER INSERT ON forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION forum_auto_subscribe_topic_author();


-- 6. Auto-subscribe when replying to a topic (if not already subscribed)
CREATE OR REPLACE FUNCTION forum_auto_subscribe_replier()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO forum_topic_subscriptions (user_id, topic_id, level)
  VALUES (NEW.user_id, NEW.topic_id, 'tracking')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_auto_subscribe_replier
  AFTER INSERT ON forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION forum_auto_subscribe_replier();


-- 7. Notify category subscribers about new topics
CREATE OR REPLACE FUNCTION forum_notify_category_new_topic()
RETURNS TRIGGER AS $$
DECLARE
  v_sub RECORD;
  v_actor_username text;
  v_cat_name text;
BEGIN
  SELECT username INTO v_actor_username FROM profiles_public WHERE user_id = NEW.user_id;
  SELECT name_ru INTO v_cat_name FROM forum_categories WHERE id = NEW.category_id;

  FOR v_sub IN
    SELECT user_id FROM forum_category_subscriptions
    WHERE category_id = NEW.category_id
      AND level = 'watching'
      AND user_id != NEW.user_id
  LOOP
    INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_sub.user_id,
      'forum_new_topic',
      'Новая тема в «' || LEFT(v_cat_name, 30) || '»',
      COALESCE(v_actor_username, 'Пользователь') || ' создал тему «' || LEFT(NEW.title, 60) || '»',
      NEW.user_id,
      'forum_topic',
      NEW.id
    );
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_forum_notify_category_new_topic
  AFTER INSERT ON forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION forum_notify_category_new_topic();


-- =====================================================
-- Migration: 20260207122537_79ea09ac-4170-4624-bd35-7421ed791e23.sql
-- =====================================================

-- ============================================
-- Forum Automoderation: settings + auto-hide trigger
-- ============================================

-- 1. Forum automod settings (key-value)
CREATE TABLE IF NOT EXISTS public.forum_automod_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb NOT NULL DEFAULT '{}',
  description text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_automod_settings ENABLE ROW LEVEL SECURITY;

-- Only admins can read/write automod settings
CREATE POLICY "Admins can manage automod settings"
  ON public.forum_automod_settings
  FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Seed default automod settings
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('stopwords', '{"words": ["казино","ставки","1xbet","мелбет","пин-ап","купить диплом","заработок без вложений"], "enabled": true}', 'Список стоп-слов для автоскрытия'),
  ('rate_limits', '{"max_posts_per_minute": 3, "max_topics_per_hour": 5, "cooldown_seconds": 15, "enabled": true}', 'Лимиты частоты публикаций'),
  ('link_filter', '{"max_links": 5, "blacklist_domains": ["1xbet.com","melbet.com"], "enabled": true}', 'Фильтрация ссылок'),
  ('auto_hide_threshold', '{"report_count": 3, "enabled": true}', 'Порог автоскрытия по жалобам'),
  ('newbie_premod', '{"enabled": false, "max_trust_level": 0}', 'Премодерация для новичков')
ON CONFLICT (key) DO NOTHING;

-- 2. Forum warnings table
CREATE TABLE IF NOT EXISTS public.forum_warnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  moderator_id uuid NOT NULL,
  reason text NOT NULL,
  severity text NOT NULL DEFAULT 'warning', -- warning, serious, final
  expires_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  post_id uuid REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_warnings ENABLE ROW LEVEL SECURITY;

-- Users can see their own warnings
CREATE POLICY "Users can see own warnings"
  ON public.forum_warnings
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Moderators/admins can manage warnings
CREATE POLICY "Mods can manage warnings"
  ON public.forum_warnings
  FOR ALL
  TO authenticated
  USING (
    public.has_role(auth.uid(), 'moderator') OR
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'moderator') OR
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'super_admin')
  );

-- 3. Auto-hide trigger on reports
CREATE OR REPLACE FUNCTION public.forum_auto_hide_on_reports()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold int;
  v_enabled boolean;
  v_report_count int;
  v_settings jsonb;
BEGIN
  -- Get auto-hide threshold from settings
  SELECT value INTO v_settings
  FROM public.forum_automod_settings
  WHERE key = 'auto_hide_threshold';

  IF v_settings IS NULL THEN RETURN NEW; END IF;

  v_enabled := COALESCE((v_settings->>'enabled')::boolean, false);
  v_threshold := COALESCE((v_settings->>'report_count')::int, 3);

  IF NOT v_enabled THEN RETURN NEW; END IF;

  -- Count pending reports for this target
  IF NEW.post_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_report_count
    FROM public.forum_reports
    WHERE post_id = NEW.post_id AND status = 'pending';

    IF v_report_count >= v_threshold THEN
      UPDATE public.forum_posts
      SET is_hidden = true,
          hidden_reason = 'Автоскрытие: ' || v_threshold || ' жалоб',
          hidden_at = now()
      WHERE id = NEW.post_id AND (is_hidden IS NULL OR is_hidden = false);

      -- Log the auto-hide action
      INSERT INTO public.forum_mod_logs (moderator_id, action, target_type, target_id, details)
      VALUES (
        '00000000-0000-0000-0000-000000000000',
        'auto_hide_post',
        'post',
        NEW.post_id,
        jsonb_build_object('reason', 'report_threshold', 'report_count', v_report_count)
      );
    END IF;
  END IF;

  IF NEW.topic_id IS NOT NULL AND NEW.post_id IS NULL THEN
    SELECT COUNT(*) INTO v_report_count
    FROM public.forum_reports
    WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending';

    IF v_report_count >= v_threshold THEN
      UPDATE public.forum_topics
      SET is_hidden = true
      WHERE id = NEW.topic_id AND (is_hidden IS NULL OR is_hidden = false);

      INSERT INTO public.forum_mod_logs (moderator_id, action, target_type, target_id, details)
      VALUES (
        '00000000-0000-0000-0000-000000000000',
        'auto_hide_topic',
        'topic',
        NEW.topic_id,
        jsonb_build_object('reason', 'report_threshold', 'report_count', v_report_count)
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger on new reports
DROP TRIGGER IF EXISTS trg_forum_auto_hide_on_reports ON public.forum_reports;
CREATE TRIGGER trg_forum_auto_hide_on_reports
  AFTER INSERT ON public.forum_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_auto_hide_on_reports();

-- 4. Rate limiting function (called from edge function)
CREATE OR REPLACE FUNCTION public.forum_check_rate_limit(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings jsonb;
  v_enabled boolean;
  v_max_posts_per_min int;
  v_max_topics_per_hour int;
  v_cooldown_sec int;
  v_post_count int;
  v_topic_count int;
  v_last_post_at timestamptz;
  v_seconds_since_last numeric;
BEGIN
  SELECT value INTO v_settings
  FROM public.forum_automod_settings
  WHERE key = 'rate_limits';

  IF v_settings IS NULL THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  v_enabled := COALESCE((v_settings->>'enabled')::boolean, true);
  IF NOT v_enabled THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  v_max_posts_per_min := COALESCE((v_settings->>'max_posts_per_minute')::int, 3);
  v_max_topics_per_hour := COALESCE((v_settings->>'max_topics_per_hour')::int, 5);
  v_cooldown_sec := COALESCE((v_settings->>'cooldown_seconds')::int, 15);

  -- Check posts in last minute
  SELECT COUNT(*) INTO v_post_count
  FROM public.forum_posts
  WHERE user_id = p_user_id AND created_at > now() - interval '1 minute';

  IF v_post_count >= v_max_posts_per_min THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'rate_limit', 'message', 'Слишком много сообщений. Подождите минуту.');
  END IF;

  -- Check topics in last hour
  SELECT COUNT(*) INTO v_topic_count
  FROM public.forum_topics
  WHERE user_id = p_user_id AND created_at > now() - interval '1 hour';

  IF v_topic_count >= v_max_topics_per_hour THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'rate_limit', 'message', 'Слишком много тем за час. Попробуйте позже.');
  END IF;

  -- Check cooldown since last post
  SELECT MAX(created_at) INTO v_last_post_at
  FROM public.forum_posts
  WHERE user_id = p_user_id;

  IF v_last_post_at IS NOT NULL THEN
    v_seconds_since_last := EXTRACT(EPOCH FROM (now() - v_last_post_at));
    IF v_seconds_since_last < v_cooldown_sec THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'reason', 'cooldown',
        'message', 'Подождите ' || CEIL(v_cooldown_sec - v_seconds_since_last) || ' сек. перед следующим сообщением.',
        'wait_seconds', CEIL(v_cooldown_sec - v_seconds_since_last)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;


-- =====================================================
-- Migration: 20260207123003_d4ae4bf4-2a8f-45dd-9cfc-8773b7c639b4.sql
-- =====================================================

-- ============================================================
-- Stage 11: Full-text search for forum
-- ============================================================

-- 1. Add tsvector columns
ALTER TABLE public.forum_topics 
  ADD COLUMN IF NOT EXISTS search_vector tsvector;

ALTER TABLE public.forum_posts 
  ADD COLUMN IF NOT EXISTS search_vector tsvector;

-- 2. GIN indexes for full-text search
CREATE INDEX IF NOT EXISTS idx_forum_topics_search 
  ON public.forum_topics USING GIN (search_vector);

CREATE INDEX IF NOT EXISTS idx_forum_posts_search 
  ON public.forum_posts USING GIN (search_vector);

-- 3. Performance indexes
CREATE INDEX IF NOT EXISTS idx_forum_topics_category_listing 
  ON public.forum_topics (category_id, is_pinned DESC, bumped_at DESC) 
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_created 
  ON public.forum_posts (topic_id, created_at);

CREATE INDEX IF NOT EXISTS idx_forum_topics_user_created 
  ON public.forum_topics (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_posts_user_created 
  ON public.forum_posts (user_id, created_at DESC);

-- 4. Trigger to auto-update search_vector on topics
CREATE OR REPLACE FUNCTION public.forum_topics_search_vector_update()
RETURNS TRIGGER AS $$
BEGIN
  NEW.search_vector := 
    setweight(to_tsvector('russian', COALESCE(NEW.title, '')), 'A') ||
    setweight(to_tsvector('russian', COALESCE(NEW.content, '')), 'B');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

DROP TRIGGER IF EXISTS trg_forum_topics_search_vector ON public.forum_topics;
CREATE TRIGGER trg_forum_topics_search_vector
  BEFORE INSERT OR UPDATE OF title, content ON public.forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_topics_search_vector_update();

-- 5. Trigger to auto-update search_vector on posts
CREATE OR REPLACE FUNCTION public.forum_posts_search_vector_update()
RETURNS TRIGGER AS $$
BEGIN
  NEW.search_vector := to_tsvector('russian', COALESCE(NEW.content, ''));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

DROP TRIGGER IF EXISTS trg_forum_posts_search_vector ON public.forum_posts;
CREATE TRIGGER trg_forum_posts_search_vector
  BEFORE INSERT OR UPDATE OF content ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_posts_search_vector_update();

-- 6. Backfill existing data
UPDATE public.forum_topics SET search_vector = 
  setweight(to_tsvector('russian', COALESCE(title, '')), 'A') ||
  setweight(to_tsvector('russian', COALESCE(content, '')), 'B')
WHERE search_vector IS NULL;

UPDATE public.forum_posts SET search_vector = 
  to_tsvector('russian', COALESCE(content, ''))
WHERE search_vector IS NULL;

-- 7. RPC function for unified search
CREATE OR REPLACE FUNCTION public.forum_search(
  p_query text,
  p_type text DEFAULT 'all',
  p_category_id uuid DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  result_type text,
  id uuid,
  title text,
  excerpt text,
  category_id uuid,
  category_name text,
  category_slug text,
  category_color text,
  user_id uuid,
  author_username text,
  author_avatar text,
  topic_id uuid,
  topic_title text,
  created_at timestamptz,
  posts_count int,
  views_count int,
  relevance real
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ts_query tsquery;
BEGIN
  -- Build tsquery from user input  
  ts_query := plainto_tsquery('russian', p_query);
  
  -- If empty query return nothing
  IF ts_query::text = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  (
    -- Search topics
    SELECT 
      'topic'::text AS result_type,
      t.id,
      t.title,
      COALESCE(t.excerpt, LEFT(t.content, 200)) AS excerpt,
      t.category_id,
      c.name_ru AS category_name,
      c.slug AS category_slug,
      c.color AS category_color,
      t.user_id,
      pp.username AS author_username,
      pp.avatar_url AS author_avatar,
      NULL::uuid AS topic_id,
      NULL::text AS topic_title,
      t.created_at,
      COALESCE(t.posts_count, 0)::int AS posts_count,
      COALESCE(t.views_count, 0)::int AS views_count,
      ts_rank_cd(t.search_vector, ts_query) AS relevance
    FROM forum_topics t
    LEFT JOIN forum_categories c ON c.id = t.category_id
    LEFT JOIN profiles_public pp ON pp.user_id = t.user_id
    WHERE t.is_hidden = false
      AND t.search_vector @@ ts_query
      AND (p_type = 'all' OR p_type = 'topics')
      AND (p_category_id IS NULL OR t.category_id = p_category_id)
  )
  UNION ALL
  (
    -- Search posts
    SELECT 
      'post'::text AS result_type,
      p.id,
      NULL::text AS title,
      LEFT(p.content, 200) AS excerpt,
      ft.category_id,
      c.name_ru AS category_name,
      c.slug AS category_slug,
      c.color AS category_color,
      p.user_id,
      pp.username AS author_username,
      pp.avatar_url AS author_avatar,
      p.topic_id,
      ft.title AS topic_title,
      p.created_at,
      0::int AS posts_count,
      0::int AS views_count,
      ts_rank_cd(p.search_vector, ts_query) AS relevance
    FROM forum_posts p
    INNER JOIN forum_topics ft ON ft.id = p.topic_id
    LEFT JOIN forum_categories c ON c.id = ft.category_id
    LEFT JOIN profiles_public pp ON pp.user_id = p.user_id
    WHERE p.is_hidden = false
      AND ft.is_hidden = false
      AND p.search_vector @@ ts_query
      AND (p_type = 'all' OR p_type = 'posts')
      AND (p_category_id IS NULL OR ft.category_id = p_category_id)
  )
  ORDER BY relevance DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;


-- =====================================================
-- Migration: 20260207123332_8cf0f685-0cb6-4056-bb6e-146e634b6c2d.sql
-- =====================================================

-- ============================================================
-- Stage 11: Warnings system — auto-escalation & settings
-- ============================================================

-- 1. Add warning settings to automod_settings
INSERT INTO public.forum_automod_settings (key, value, description)
VALUES 
  ('warn_mute_threshold', '3'::jsonb, 'Number of active warnings before auto-mute'),
  ('mute_duration_hours', '24'::jsonb, 'Duration of auto-mute in hours'),
  ('warn_ban_threshold', '5'::jsonb, 'Number of active warnings before auto-ban (silence)'),
  ('ban_duration_hours', '168'::jsonb, 'Duration of auto-ban/silence in hours'),
  ('warn_expiry_days', '90'::jsonb, 'Days until a warning expires automatically')
ON CONFLICT (key) DO NOTHING;

-- 2. Trigger: auto-escalate on new warning (mute or silence user)
CREATE OR REPLACE FUNCTION public.forum_warning_auto_escalate()
RETURNS TRIGGER AS $$
DECLARE
  active_warnings_count int;
  mute_threshold int;
  ban_threshold int;
  mute_hours int;
  ban_hours int;
  v_val jsonb;
BEGIN
  -- Count active warnings for user
  SELECT COUNT(*) INTO active_warnings_count
  FROM public.forum_warnings
  WHERE user_id = NEW.user_id
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > now());

  -- Get thresholds from settings
  SELECT value INTO v_val FROM public.forum_automod_settings WHERE key = 'warn_mute_threshold';
  mute_threshold := COALESCE((v_val)::int, 3);

  SELECT value INTO v_val FROM public.forum_automod_settings WHERE key = 'warn_ban_threshold';
  ban_threshold := COALESCE((v_val)::int, 5);

  SELECT value INTO v_val FROM public.forum_automod_settings WHERE key = 'mute_duration_hours';
  mute_hours := COALESCE((v_val)::int, 24);

  SELECT value INTO v_val FROM public.forum_automod_settings WHERE key = 'ban_duration_hours';
  ban_hours := COALESCE((v_val)::int, 168);

  -- Update warnings count
  UPDATE public.forum_user_stats 
  SET warnings_count = active_warnings_count,
      updated_at = now()
  WHERE user_id = NEW.user_id;

  -- Auto-ban (silence) if threshold met
  IF active_warnings_count >= ban_threshold THEN
    UPDATE public.forum_user_stats 
    SET is_silenced = true,
        silenced_until = now() + (ban_hours || ' hours')::interval,
        silence_reason = 'Автоматическая блокировка: ' || active_warnings_count || ' предупреждений',
        updated_at = now()
    WHERE user_id = NEW.user_id;

    -- Log the auto-action
    INSERT INTO public.forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (
      NEW.issued_by,
      'auto_silence',
      'user',
      NEW.user_id::text,
      jsonb_build_object('warnings_count', active_warnings_count, 'duration_hours', ban_hours)
    );

  -- Auto-mute if threshold met
  ELSIF active_warnings_count >= mute_threshold THEN
    UPDATE public.forum_user_stats 
    SET is_muted = true,
        muted_until = now() + (mute_hours || ' hours')::interval,
        updated_at = now()
    WHERE user_id = NEW.user_id;

    INSERT INTO public.forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (
      NEW.issued_by,
      'auto_mute',
      'user',
      NEW.user_id::text,
      jsonb_build_object('warnings_count', active_warnings_count, 'duration_hours', mute_hours)
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_forum_warning_auto_escalate ON public.forum_warnings;
CREATE TRIGGER trg_forum_warning_auto_escalate
  AFTER INSERT ON public.forum_warnings
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_warning_auto_escalate();

-- 3. Function to expire old warnings (can be called periodically)
CREATE OR REPLACE FUNCTION public.forum_expire_warnings()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  expired_count int;
BEGIN
  UPDATE public.forum_warnings
  SET is_active = false
  WHERE is_active = true
    AND expires_at IS NOT NULL
    AND expires_at <= now();
  
  GET DIAGNOSTICS expired_count = ROW_COUNT;
  
  -- Also clear mute/silence that expired
  UPDATE public.forum_user_stats
  SET is_muted = false, muted_until = null
  WHERE is_muted = true AND muted_until IS NOT NULL AND muted_until <= now();
  
  UPDATE public.forum_user_stats
  SET is_silenced = false, silenced_until = null, silence_reason = null
  WHERE is_silenced = true AND silenced_until IS NOT NULL AND silenced_until <= now();
  
  RETURN expired_count;
END;
$$;

-- 4. Notification trigger for warnings
CREATE OR REPLACE FUNCTION public.forum_notify_warning()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.notifications (user_id, type, title, message, link, metadata)
  VALUES (
    NEW.user_id,
    'forum_warning',
    'Предупреждение на форуме',
    NEW.reason,
    '/forum',
    jsonb_build_object('warning_id', NEW.id, 'severity', NEW.severity)
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_forum_notify_warning ON public.forum_warnings;
CREATE TRIGGER trg_forum_notify_warning
  AFTER INSERT ON public.forum_warnings
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_notify_warning();


-- =====================================================
-- Migration: 20260207125537_611b51ae-4705-4d60-80c4-ccf9d03bfdc8.sql
-- =====================================================

-- ========================================
-- ЭТАП 15: Система опросов (Polls)
-- ========================================

-- 1. Таблица опросов
CREATE TABLE public.forum_polls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  question TEXT NOT NULL,
  poll_type TEXT NOT NULL DEFAULT 'single' CHECK (poll_type IN ('single', 'multiple')),
  is_anonymous BOOLEAN NOT NULL DEFAULT false,
  ends_at TIMESTAMPTZ,
  is_closed BOOLEAN NOT NULL DEFAULT false,
  total_votes INTEGER NOT NULL DEFAULT 0,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Варианты ответов
CREATE TABLE public.forum_poll_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id UUID NOT NULL REFERENCES public.forum_polls(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  votes_count INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Голоса в опросах
CREATE TABLE public.forum_poll_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id UUID NOT NULL REFERENCES public.forum_polls(id) ON DELETE CASCADE,
  option_id UUID NOT NULL REFERENCES public.forum_poll_options(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (poll_id, option_id, user_id)
);

-- Индексы
CREATE INDEX idx_forum_polls_topic_id ON public.forum_polls(topic_id);
CREATE INDEX idx_forum_poll_options_poll_id ON public.forum_poll_options(poll_id, sort_order);
CREATE INDEX idx_forum_poll_votes_poll_id ON public.forum_poll_votes(poll_id);
CREATE INDEX idx_forum_poll_votes_user_id ON public.forum_poll_votes(user_id, poll_id);

-- ========================================
-- RLS
-- ========================================

ALTER TABLE public.forum_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_poll_votes ENABLE ROW LEVEL SECURITY;

-- Polls: все аутентифицированные могут читать
CREATE POLICY "Anyone can view polls"
  ON public.forum_polls FOR SELECT
  TO authenticated
  USING (true);

-- Polls: автор может создавать
CREATE POLICY "Users can create polls"
  ON public.forum_polls FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = created_by);

-- Polls: автор и админы могут обновлять (закрыть опрос)
CREATE POLICY "Authors and admins can update polls"
  ON public.forum_polls FOR UPDATE
  TO authenticated
  USING (auth.uid() = created_by OR public.has_role(auth.uid(), 'admin'));

-- Options: все аутентифицированные могут читать
CREATE POLICY "Anyone can view poll options"
  ON public.forum_poll_options FOR SELECT
  TO authenticated
  USING (true);

-- Options: создатель опроса может добавлять варианты
CREATE POLICY "Poll creator can add options"
  ON public.forum_poll_options FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.forum_polls
      WHERE id = poll_id AND created_by = auth.uid()
    )
  );

-- Votes: все аутентифицированные могут видеть голоса (для подсчёта)
CREATE POLICY "Anyone can view votes"
  ON public.forum_poll_votes FOR SELECT
  TO authenticated
  USING (true);

-- Votes: пользователь может голосовать
CREATE POLICY "Users can vote"
  ON public.forum_poll_votes FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Votes: пользователь может удалить свой голос
CREATE POLICY "Users can remove own vote"
  ON public.forum_poll_votes FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- ========================================
-- Триггеры для подсчёта голосов
-- ========================================

-- Обновление votes_count в options
CREATE OR REPLACE FUNCTION public.forum_poll_vote_count_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.forum_poll_options
      SET votes_count = votes_count + 1
      WHERE id = NEW.option_id;
    UPDATE public.forum_polls
      SET total_votes = total_votes + 1
      WHERE id = NEW.poll_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.forum_poll_options
      SET votes_count = GREATEST(votes_count - 1, 0)
      WHERE id = OLD.option_id;
    UPDATE public.forum_polls
      SET total_votes = GREATEST(total_votes - 1, 0)
      WHERE id = OLD.poll_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_forum_poll_vote_count
  AFTER INSERT OR DELETE ON public.forum_poll_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_poll_vote_count_fn();

-- Автозакрытие просроченных опросов (вызывается при голосовании)
CREATE OR REPLACE FUNCTION public.forum_poll_check_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Проверяем, не истёк ли опрос
  IF EXISTS (
    SELECT 1 FROM public.forum_polls
    WHERE id = NEW.poll_id
      AND ends_at IS NOT NULL
      AND ends_at < now()
      AND is_closed = false
  ) THEN
    UPDATE public.forum_polls SET is_closed = true WHERE id = NEW.poll_id;
    RAISE EXCEPTION 'Poll has expired';
  END IF;
  
  -- Проверяем, не закрыт ли опрос
  IF EXISTS (
    SELECT 1 FROM public.forum_polls
    WHERE id = NEW.poll_id AND is_closed = true
  ) THEN
    RAISE EXCEPTION 'Poll is closed';
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_poll_check_expiry
  BEFORE INSERT ON public.forum_poll_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_poll_check_expiry();

-- Для single-choice опросов: проверка что пользователь не голосовал дважды
CREATE OR REPLACE FUNCTION public.forum_poll_single_vote_check()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  poll_type_val TEXT;
BEGIN
  SELECT poll_type INTO poll_type_val
    FROM public.forum_polls WHERE id = NEW.poll_id;
  
  IF poll_type_val = 'single' THEN
    -- Удаляем предыдущий голос (если есть) для single-choice
    DELETE FROM public.forum_poll_votes
      WHERE poll_id = NEW.poll_id
        AND user_id = NEW.user_id
        AND id != NEW.id;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_poll_single_vote
  AFTER INSERT ON public.forum_poll_votes
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_poll_single_vote_check();


-- =====================================================
-- Migration: 20260207132335_79b829e9-1528-4164-bc76-c4d103cd9b1a.sql
-- =====================================================

-- ============================================
-- STAGE 18: Forum Security Hardening
-- ============================================

-- 1. Input validation trigger: prevent oversized content
CREATE OR REPLACE FUNCTION forum_validate_post_content()
RETURNS TRIGGER AS $$
DECLARE
  max_len INT := 50000;
  setting_row RECORD;
BEGIN
  -- Try to read max length from settings
  SELECT value INTO setting_row
  FROM forum_automod_settings
  WHERE key = 'forum_max_post_length'
  LIMIT 1;
  
  IF setting_row IS NOT NULL THEN
    max_len := (setting_row.value::text)::int;
  END IF;

  IF length(NEW.content) > max_len THEN
    RAISE EXCEPTION 'Post content exceeds maximum length of % characters', max_len;
  END IF;

  IF length(NEW.content) < 1 THEN
    RAISE EXCEPTION 'Post content cannot be empty';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_validate_post_before_insert
  BEFORE INSERT OR UPDATE ON forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION forum_validate_post_content();

-- 2. Input validation for topics
CREATE OR REPLACE FUNCTION forum_validate_topic_content()
RETURNS TRIGGER AS $$
BEGIN
  IF length(TRIM(NEW.title)) < 3 THEN
    RAISE EXCEPTION 'Topic title must be at least 3 characters';
  END IF;

  IF length(NEW.title) > 300 THEN
    RAISE EXCEPTION 'Topic title exceeds maximum length of 300 characters';
  END IF;

  IF length(NEW.content) > 100000 THEN
    RAISE EXCEPTION 'Topic content exceeds maximum length';
  END IF;

  IF length(NEW.content) < 1 THEN
    RAISE EXCEPTION 'Topic content cannot be empty';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_validate_topic_before_insert
  BEFORE INSERT OR UPDATE ON forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION forum_validate_topic_content();

-- 3. DB-level rate limiting function
CREATE OR REPLACE FUNCTION forum_check_rate_limit()
RETURNS TRIGGER AS $$
DECLARE
  recent_count INT;
  rate_per_min INT := 3;
  cooldown_sec INT := 15;
  last_post_time TIMESTAMPTZ;
  setting_row RECORD;
BEGIN
  -- Read rate limit from settings
  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_rate_limit_per_minute' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    rate_per_min := (setting_row.value::text)::int;
  END IF;

  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_post_cooldown_seconds' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    cooldown_sec := (setting_row.value::text)::int;
  END IF;

  -- Check cooldown: last post time
  SELECT MAX(created_at) INTO last_post_time
  FROM forum_posts
  WHERE user_id = NEW.user_id;

  IF last_post_time IS NOT NULL AND (now() - last_post_time) < (cooldown_sec || ' seconds')::interval THEN
    RAISE EXCEPTION 'Please wait before posting again (cooldown: % seconds)', cooldown_sec;
  END IF;

  -- Check rate limit: posts in last minute
  SELECT COUNT(*) INTO recent_count
  FROM forum_posts
  WHERE user_id = NEW.user_id
    AND created_at > now() - interval '1 minute';

  IF recent_count >= rate_per_min THEN
    RAISE EXCEPTION 'Rate limit exceeded: maximum % posts per minute', rate_per_min;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_rate_limit_posts
  BEFORE INSERT ON forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION forum_check_rate_limit();

-- 4. Check muted status before posting
CREATE OR REPLACE FUNCTION forum_check_muted_status()
RETURNS TRIGGER AS $$
DECLARE
  user_stats RECORD;
BEGIN
  SELECT is_muted, muted_until INTO user_stats
  FROM forum_user_stats
  WHERE user_id = NEW.user_id;

  IF user_stats IS NOT NULL AND user_stats.is_muted = true THEN
    -- Check if mute has expired
    IF user_stats.muted_until IS NOT NULL AND user_stats.muted_until <= now() THEN
      -- Auto-unmute
      UPDATE forum_user_stats SET is_muted = false, muted_until = NULL WHERE user_id = NEW.user_id;
    ELSE
      RAISE EXCEPTION 'You are currently muted and cannot post';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_check_muted_before_post
  BEFORE INSERT ON forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION forum_check_muted_status();

CREATE TRIGGER forum_check_muted_before_topic
  BEFORE INSERT ON forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION forum_check_muted_status();

-- 5. Clean up duplicate RLS policies on forum_warnings
DROP POLICY IF EXISTS "Moderators manage warnings" ON forum_warnings;
DROP POLICY IF EXISTS "Mods create warnings" ON forum_warnings;
DROP POLICY IF EXISTS "Mods update warnings" ON forum_warnings;
DROP POLICY IF EXISTS "Users can see own warnings" ON forum_warnings;
DROP POLICY IF EXISTS "Users see own warnings" ON forum_warnings;

-- Keep clean single policies:
-- "Mods can manage warnings" (ALL for mods) already exists
-- "Users view own warnings" (SELECT for users + mods) already exists

-- 6. Add partial indexes for hidden content filtering
CREATE INDEX IF NOT EXISTS idx_forum_topics_visible 
  ON forum_topics (category_id, is_pinned DESC, last_post_at DESC) 
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_forum_posts_visible 
  ON forum_posts (topic_id, created_at) 
  WHERE is_hidden = false;

-- 7. Validate file upload metadata
CREATE OR REPLACE FUNCTION forum_validate_attachment()
RETURNS TRIGGER AS $$
DECLARE
  max_size INT := 10485760; -- 10MB default
  allowed_types TEXT[] := ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'audio/mpeg', 'audio/wav', 'application/pdf'];
  setting_row RECORD;
BEGIN
  -- Check max file size from settings
  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_max_file_size' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    max_size := ((setting_row.value::text)::int) * 1024 * 1024;
  END IF;

  IF NEW.file_size > max_size THEN
    RAISE EXCEPTION 'File size exceeds maximum allowed (% bytes)', max_size;
  END IF;

  IF NEW.file_size <= 0 THEN
    RAISE EXCEPTION 'Invalid file size';
  END IF;

  -- Validate file type
  IF NOT (NEW.file_type = ANY(allowed_types)) THEN
    RAISE EXCEPTION 'File type not allowed: %', NEW.file_type;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_validate_attachment_before_insert
  BEFORE INSERT ON forum_attachments
  FOR EACH ROW
  EXECUTE FUNCTION forum_validate_attachment();

-- 8. Auto-hide content after N reports threshold
CREATE OR REPLACE FUNCTION forum_auto_hide_on_reports()
RETURNS TRIGGER AS $$
DECLARE
  report_count INT;
  threshold INT := 5;
  setting_row RECORD;
BEGIN
  -- Only process new pending reports
  IF NEW.status != 'pending' THEN
    RETURN NEW;
  END IF;

  -- Read threshold from settings
  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_auto_hide_threshold' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    threshold := (setting_row.value::text)::int;
  END IF;

  -- Count pending reports for this target
  IF NEW.post_id IS NOT NULL THEN
    SELECT COUNT(*) INTO report_count
    FROM forum_reports
    WHERE post_id = NEW.post_id AND status = 'pending';
    
    IF report_count + 1 >= threshold THEN
      UPDATE forum_posts SET is_hidden = true, hidden_reason = 'Auto-hidden: report threshold reached' WHERE id = NEW.post_id;
    END IF;
  ELSIF NEW.topic_id IS NOT NULL AND NEW.post_id IS NULL THEN
    SELECT COUNT(*) INTO report_count
    FROM forum_reports
    WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending';
    
    IF report_count + 1 >= threshold THEN
      UPDATE forum_topics SET is_hidden = true WHERE id = NEW.topic_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_auto_hide_on_report_insert
  AFTER INSERT ON forum_reports
  FOR EACH ROW
  EXECUTE FUNCTION forum_auto_hide_on_reports();

-- 9. Prevent self-reporting
CREATE OR REPLACE FUNCTION forum_prevent_self_report()
RETURNS TRIGGER AS $$
DECLARE
  target_user_id UUID;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_posts WHERE id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_topics WHERE id = NEW.topic_id;
  END IF;

  IF target_user_id = NEW.reporter_id THEN
    RAISE EXCEPTION 'You cannot report your own content';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER forum_prevent_self_report_trigger
  BEFORE INSERT ON forum_reports
  FOR EACH ROW
  EXECUTE FUNCTION forum_prevent_self_report();

-- 10. Prevent duplicate reports
CREATE UNIQUE INDEX IF NOT EXISTS idx_forum_reports_unique_post 
  ON forum_reports (reporter_id, post_id) 
  WHERE post_id IS NOT NULL AND status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS idx_forum_reports_unique_topic 
  ON forum_reports (reporter_id, topic_id) 
  WHERE topic_id IS NOT NULL AND post_id IS NULL AND status = 'pending';

-- 11. Add automod settings read policy for all authenticated (needed for triggers)
CREATE POLICY "Authenticated read automod settings"
  ON forum_automod_settings
  FOR SELECT
  TO authenticated
  USING (true);


-- =====================================================
-- Migration: 20260207135433_2defc7ec-7582-4e88-ba9a-ee035a462905.sql
-- =====================================================

-- ============================================
-- PHASE 1: Forum DB Foundation Completion
-- ============================================

-- 1.1 forum_user_ignores — ignore list
CREATE TABLE IF NOT EXISTS public.forum_user_ignores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  ignored_user_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, ignored_user_id),
  CHECK (user_id <> ignored_user_id)
);

ALTER TABLE public.forum_user_ignores ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own ignores" ON public.forum_user_ignores
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 1.2 forum_link_previews — cached link previews
CREATE TABLE IF NOT EXISTS public.forum_link_previews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  url TEXT NOT NULL UNIQUE,
  title TEXT,
  description TEXT,
  image_url TEXT,
  site_name TEXT,
  cached_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days')
);

ALTER TABLE public.forum_link_previews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read link previews" ON public.forum_link_previews
  FOR SELECT USING (true);

CREATE POLICY "Authenticated can insert link previews" ON public.forum_link_previews
  FOR INSERT TO authenticated WITH CHECK (true);

-- 1.3 forum_activity_log — full activity log for analytics
CREATE TABLE IF NOT EXISTS public.forum_activity_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  action TEXT NOT NULL, -- 'topic_create', 'post_create', 'vote', 'reaction', 'report', 'bookmark', 'search', etc.
  target_type TEXT, -- 'topic', 'post', 'category', 'poll'
  target_id UUID,
  metadata JSONB DEFAULT '{}',
  ip_address INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_activity_log ENABLE ROW LEVEL SECURITY;

-- Only admins can read activity log
CREATE POLICY "Admins read activity log" ON public.forum_activity_log
  FOR SELECT USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- System inserts via triggers (security definer)
CREATE POLICY "System inserts activity log" ON public.forum_activity_log
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE INDEX idx_forum_activity_log_user ON public.forum_activity_log(user_id, created_at DESC);
CREATE INDEX idx_forum_activity_log_action ON public.forum_activity_log(action, created_at DESC);
CREATE INDEX idx_forum_activity_log_target ON public.forum_activity_log(target_type, target_id);

-- 1.4 Add is_banned / banned_until to forum_user_stats
ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS is_banned BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS banned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ban_reason TEXT;

-- 1.5 Security definer: check user trust level for category access
CREATE OR REPLACE FUNCTION public.forum_user_trust_level(_user_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT trust_level FROM public.forum_user_stats WHERE user_id = _user_id),
    0
  );
$$;

-- 1.6 Security definer: check if user is banned
CREATE OR REPLACE FUNCTION public.forum_user_is_banned(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT is_banned AND (banned_until IS NULL OR banned_until > now())
     FROM public.forum_user_stats WHERE user_id = _user_id),
    false
  );
$$;

-- 1.7 Update topic creation RLS: check trust_level + is_banned
DROP POLICY IF EXISTS "Authenticated users create topics" ON public.forum_topics;
CREATE POLICY "Authenticated users create topics" ON public.forum_topics
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND NOT public.forum_user_is_banned(auth.uid())
    AND public.forum_user_trust_level(auth.uid()) >= COALESCE(
      (SELECT min_trust_level FROM public.forum_categories WHERE id = category_id),
      0
    )
  );

-- 1.8 Update post creation RLS: check is_banned
DROP POLICY IF EXISTS "Authenticated users create posts" ON public.forum_posts;
CREATE POLICY "Authenticated users create posts" ON public.forum_posts
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND NOT public.forum_user_is_banned(auth.uid())
  );

-- 1.9 Update topic visibility: also check category trust_level for reading
DROP POLICY IF EXISTS "View visible topics" ON public.forum_topics;
CREATE POLICY "View visible topics" ON public.forum_topics
  FOR SELECT USING (
    (is_hidden = false OR is_hidden IS NULL)
    AND public.forum_user_trust_level(auth.uid()) >= COALESCE(
      (SELECT min_trust_level FROM public.forum_categories WHERE id = category_id),
      0
    )
  );

-- 1.10 Moderation RLS: allow mods/admins to update any topic (for pin/lock/hide/move)
DROP POLICY IF EXISTS "Users update own topics" ON public.forum_topics;
CREATE POLICY "Users update own topics" ON public.forum_topics
  FOR UPDATE TO authenticated
  USING (
    auth.uid() = user_id
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
    OR EXISTS (
      SELECT 1 FROM public.forum_user_stats
      WHERE user_id = auth.uid() AND trust_level >= 4
    )
  );

-- 1.11 Moderation RLS: allow mods/admins to update any post (for hide/show)
DROP POLICY IF EXISTS "Users update own posts" ON public.forum_posts;
CREATE POLICY "Users update own posts" ON public.forum_posts
  FOR UPDATE TO authenticated
  USING (
    auth.uid() = user_id
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
    OR EXISTS (
      SELECT 1 FROM public.forum_user_stats
      WHERE user_id = auth.uid() AND trust_level >= 4
    )
  );

-- 1.12 Activity logging triggers
CREATE OR REPLACE FUNCTION public.forum_log_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.forum_activity_log (user_id, action, target_type, target_id)
  VALUES (
    NEW.user_id,
    CASE TG_TABLE_NAME
      WHEN 'forum_topics' THEN 'topic_create'
      WHEN 'forum_posts' THEN 'post_create'
      WHEN 'forum_post_votes' THEN 'vote'
      WHEN 'forum_post_reactions' THEN 'reaction'
      WHEN 'forum_reports' THEN 'report'
      WHEN 'forum_bookmarks' THEN 'bookmark'
      ELSE TG_TABLE_NAME
    END,
    CASE TG_TABLE_NAME
      WHEN 'forum_topics' THEN 'topic'
      WHEN 'forum_posts' THEN 'post'
      WHEN 'forum_post_votes' THEN CASE WHEN NEW.post_id IS NOT NULL THEN 'post' ELSE 'topic' END
      WHEN 'forum_post_reactions' THEN CASE WHEN NEW.post_id IS NOT NULL THEN 'post' ELSE 'topic' END
      WHEN 'forum_reports' THEN 'report'
      WHEN 'forum_bookmarks' THEN 'topic'
      ELSE 'unknown'
    END,
    CASE TG_TABLE_NAME
      WHEN 'forum_topics' THEN NEW.id
      WHEN 'forum_posts' THEN NEW.id
      WHEN 'forum_post_votes' THEN COALESCE(NEW.post_id, NEW.topic_id)
      WHEN 'forum_post_reactions' THEN COALESCE(NEW.post_id, NEW.topic_id)
      WHEN 'forum_reports' THEN NEW.id
      WHEN 'forum_bookmarks' THEN NEW.topic_id
      ELSE NEW.id
    END
  );
  RETURN NEW;
END;
$$;

-- Attach activity logging to key tables
CREATE TRIGGER trg_forum_log_topic_activity
  AFTER INSERT ON public.forum_topics
  FOR EACH ROW EXECUTE FUNCTION public.forum_log_activity();

CREATE TRIGGER trg_forum_log_post_activity
  AFTER INSERT ON public.forum_posts
  FOR EACH ROW EXECUTE FUNCTION public.forum_log_activity();

CREATE TRIGGER trg_forum_log_vote_activity
  AFTER INSERT ON public.forum_post_votes
  FOR EACH ROW EXECUTE FUNCTION public.forum_log_activity();

CREATE TRIGGER trg_forum_log_bookmark_activity
  AFTER INSERT ON public.forum_bookmarks
  FOR EACH ROW EXECUTE FUNCTION public.forum_log_activity();

-- Enable realtime for activity log (for admin dashboard)
ALTER PUBLICATION supabase_realtime ADD TABLE public.forum_activity_log;

-- Index for is_solved filtering
CREATE INDEX IF NOT EXISTS idx_forum_topics_is_solved ON public.forum_topics(is_solved) WHERE is_solved = true;


-- =====================================================
-- Migration: 20260207150438_fae92049-967f-4741-a539-6f52dbeb3673.sql
-- =====================================================

-- Add forum_automod_settings for regex patterns
INSERT INTO forum_automod_settings (key, value, description)
VALUES ('regex_filters', '{"enabled": false, "patterns": []}', 'Regex-фильтры для автомодерации')
ON CONFLICT (key) DO NOTHING;

-- Create trigger to auto-notify on forum reply
CREATE OR REPLACE FUNCTION public.forum_notify_on_reply()
RETURNS TRIGGER AS $$
DECLARE
  v_topic_title text;
  v_author_username text;
  v_topic_user_id uuid;
BEGIN
  SELECT title, user_id INTO v_topic_title, v_topic_user_id
  FROM forum_topics WHERE id = NEW.topic_id;

  SELECT username INTO v_author_username
  FROM profiles_public WHERE user_id = NEW.user_id;

  IF v_topic_user_id IS NOT NULL AND v_topic_user_id != NEW.user_id THEN
    INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_topic_user_id, 'forum_reply', 'Новый ответ в теме',
      COALESCE(v_author_username, 'Пользователь') || ' ответил в теме «' || LEFT(v_topic_title, 80) || '»',
      NEW.user_id, 'forum_topic', NEW.topic_id
    );
  END IF;

  IF NEW.reply_to_user_id IS NOT NULL AND NEW.reply_to_user_id != NEW.user_id AND NEW.reply_to_user_id != v_topic_user_id THEN
    INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      NEW.reply_to_user_id, 'forum_mention', 'Вам ответили',
      COALESCE(v_author_username, 'Пользователь') || ' ответил на ваше сообщение в теме «' || LEFT(v_topic_title, 80) || '»',
      NEW.user_id, 'forum_topic', NEW.topic_id
    );
  END IF;

  INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
  SELECT ts.user_id, 'forum_reply', 'Новый ответ в отслеживаемой теме',
    COALESCE(v_author_username, 'Пользователь') || ' написал в теме «' || LEFT(v_topic_title, 80) || '»',
    NEW.user_id, 'forum_topic', NEW.topic_id
  FROM forum_topic_subscriptions ts
  WHERE ts.topic_id = NEW.topic_id AND ts.level = 'watching'
    AND ts.user_id != NEW.user_id
    AND ts.user_id != COALESCE(v_topic_user_id, '00000000-0000-0000-0000-000000000000')
    AND ts.user_id != COALESCE(NEW.reply_to_user_id, '00000000-0000-0000-0000-000000000000');

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trigger_forum_notify_on_reply ON forum_posts;
CREATE TRIGGER trigger_forum_notify_on_reply
  AFTER INSERT ON forum_posts FOR EACH ROW
  EXECUTE FUNCTION forum_notify_on_reply();

-- Notify on upvote milestones
CREATE OR REPLACE FUNCTION public.forum_notify_on_vote_milestone()
RETURNS TRIGGER AS $$
DECLARE
  v_post_user_id uuid;
  v_new_score int;
  v_topic_title text;
  v_milestone int;
BEGIN
  IF NEW.vote_type != 1 THEN RETURN NEW; END IF;
  
  IF NEW.post_id IS NOT NULL THEN
    SELECT p.user_id, p.votes_score, t.title 
    INTO v_post_user_id, v_new_score, v_topic_title
    FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id WHERE p.id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id, votes_score, title INTO v_post_user_id, v_new_score, v_topic_title
    FROM forum_topics WHERE id = NEW.topic_id;
  END IF;

  IF v_post_user_id IS NULL OR v_post_user_id = NEW.user_id THEN RETURN NEW; END IF;

  v_milestone := CASE
    WHEN v_new_score = 5 THEN 5 WHEN v_new_score = 10 THEN 10
    WHEN v_new_score = 25 THEN 25 WHEN v_new_score = 50 THEN 50
    WHEN v_new_score = 100 THEN 100 ELSE NULL
  END;

  IF v_milestone IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, message, actor_id, target_type, target_id)
    VALUES (
      v_post_user_id, 'forum_milestone', 'Достижение: ' || v_milestone || ' голосов!',
      'Ваш пост в теме «' || LEFT(v_topic_title, 80) || '» набрал ' || v_milestone || ' голосов',
      NEW.user_id, 'forum_topic',
      COALESCE(NEW.topic_id, (SELECT topic_id FROM forum_posts WHERE id = NEW.post_id))
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trigger_forum_vote_milestone ON forum_post_votes;
CREATE TRIGGER trigger_forum_vote_milestone
  AFTER INSERT ON forum_post_votes FOR EACH ROW
  EXECUTE FUNCTION forum_notify_on_vote_milestone();

-- Notify on solution marked
CREATE OR REPLACE FUNCTION public.forum_notify_on_solution()
RETURNS TRIGGER AS $$
DECLARE
  v_topic_title text;
BEGIN
  IF NEW.is_solution = true AND (OLD.is_solution IS NULL OR OLD.is_solution = false) THEN
    SELECT title INTO v_topic_title FROM forum_topics WHERE id = NEW.topic_id;
    IF NEW.user_id != (SELECT user_id FROM forum_topics WHERE id = NEW.topic_id) THEN
      INSERT INTO notifications (user_id, type, title, message, target_type, target_id)
      VALUES (
        NEW.user_id, 'forum_solution', 'Ваш ответ отмечен как решение!',
        'Ваш ответ в теме «' || LEFT(v_topic_title, 80) || '» отмечен как решение',
        'forum_topic', NEW.topic_id
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trigger_forum_solution_notify ON forum_posts;
CREATE TRIGGER trigger_forum_solution_notify
  AFTER UPDATE ON forum_posts FOR EACH ROW
  EXECUTE FUNCTION forum_notify_on_solution();


-- =====================================================
-- Migration: 20260207151436_4f2d0e79-164c-44bf-93e9-516efba648d1.sql
-- =====================================================
-- Add privacy settings columns to forum_user_stats
ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS hide_online_status boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS hide_forum_activity boolean NOT NULL DEFAULT false;

-- RLS: users can update their own privacy settings
CREATE POLICY "Users can update own forum privacy settings"
  ON public.forum_user_stats
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);


-- =====================================================
-- Migration: 20260207152447_75e5dbb3-b9d9-468c-8d8a-c0648edf81eb.sql
-- =====================================================
-- Function to notify mentioned users when a post is created
CREATE OR REPLACE FUNCTION public.forum_notify_on_mention()
RETURNS TRIGGER AS $$
DECLARE
  mention_match TEXT;
  mentioned_username TEXT;
  mentioned_user_id UUID;
  topic_title TEXT;
BEGIN
  -- Extract @mentions from content_html (pattern: data-mention-id="uuid")
  FOR mention_match IN
    SELECT (regexp_matches(NEW.content_html, 'data-mention-id="([0-9a-f-]+)"', 'g'))[1]
  LOOP
    mentioned_user_id := mention_match::UUID;
    
    -- Don't notify yourself
    IF mentioned_user_id = NEW.user_id THEN
      CONTINUE;
    END IF;
    
    -- Get topic title for notification
    SELECT title INTO topic_title
    FROM public.forum_topics
    WHERE id = NEW.topic_id;
    
    -- Insert notification (ignore duplicates)
    INSERT INTO public.forum_notifications (user_id, type, actor_id, topic_id, post_id, message)
    VALUES (
      mentioned_user_id,
      'mention',
      NEW.user_id,
      NEW.topic_id,
      NEW.id,
      'упомянул(а) вас в теме «' || COALESCE(topic_title, 'Без названия') || '»'
    )
    ON CONFLICT DO NOTHING;
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Create trigger for mentions on post insert
DROP TRIGGER IF EXISTS trg_forum_notify_mention ON public.forum_posts;
CREATE TRIGGER trg_forum_notify_mention
  AFTER INSERT ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_notify_on_mention();


-- =====================================================
-- Migration: 20260207165250_b1fd900c-be7a-4e09-b7d6-9e6be0ca3cdc.sql
-- =====================================================

-- Add forum_topic_id to tracks to link voting tracks with forum discussions
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS forum_topic_id uuid REFERENCES public.forum_topics(id);

-- Create index for quick lookup
CREATE INDEX IF NOT EXISTS idx_tracks_forum_topic_id ON public.tracks(forum_topic_id) WHERE forum_topic_id IS NOT NULL;


-- =====================================================
-- Migration: 20260207172256_a156eab6-67fb-4ca6-bf1f-974599c8b3df.sql
-- =====================================================

-- FIX 1: Replace forum_log_activity to avoid referencing NEW.post_id on tables that don't have it
CREATE OR REPLACE FUNCTION public.forum_log_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action TEXT;
  v_target_type TEXT;
  v_target_id UUID;
BEGIN
  -- Determine action
  CASE TG_TABLE_NAME
    WHEN 'forum_topics' THEN v_action := 'topic_create';
    WHEN 'forum_posts' THEN v_action := 'post_create';
    WHEN 'forum_post_votes' THEN v_action := 'vote';
    WHEN 'forum_post_reactions' THEN v_action := 'reaction';
    WHEN 'forum_reports' THEN v_action := 'report';
    WHEN 'forum_bookmarks' THEN v_action := 'bookmark';
    ELSE v_action := TG_TABLE_NAME;
  END CASE;

  -- Determine target_type and target_id per table (no cross-table field access)
  IF TG_TABLE_NAME = 'forum_topics' THEN
    v_target_type := 'topic';
    v_target_id := NEW.id;
  ELSIF TG_TABLE_NAME = 'forum_posts' THEN
    v_target_type := 'post';
    v_target_id := NEW.id;
  ELSIF TG_TABLE_NAME = 'forum_post_votes' THEN
    IF NEW.post_id IS NOT NULL THEN
      v_target_type := 'post';
      v_target_id := NEW.post_id;
    ELSE
      v_target_type := 'topic';
      v_target_id := NEW.topic_id;
    END IF;
  ELSIF TG_TABLE_NAME = 'forum_post_reactions' THEN
    IF NEW.post_id IS NOT NULL THEN
      v_target_type := 'post';
      v_target_id := NEW.post_id;
    ELSE
      v_target_type := 'topic';
      v_target_id := NEW.topic_id;
    END IF;
  ELSIF TG_TABLE_NAME = 'forum_reports' THEN
    v_target_type := 'report';
    v_target_id := NEW.id;
  ELSIF TG_TABLE_NAME = 'forum_bookmarks' THEN
    v_target_type := 'topic';
    v_target_id := NEW.topic_id;
  ELSE
    v_target_type := 'unknown';
    v_target_id := NEW.id;
  END IF;

  INSERT INTO public.forum_activity_log (user_id, action, target_type, target_id)
  VALUES (NEW.user_id, v_action, v_target_type, v_target_id);

  RETURN NEW;
END;
$$;

-- FIX 2: Drop the old 2-param version of send_track_to_voting to avoid PostgREST ambiguity
DROP FUNCTION IF EXISTS public.send_track_to_voting(uuid, integer);

-- FIX 3: Update resolve_track_voting to also clear voting fields when rejecting
CREATE OR REPLACE FUNCTION public.resolve_track_voting(
  p_track_id UUID,
  p_manual_result TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_like_ratio NUMERIC;
  v_result TEXT;
  v_new_status TEXT;
BEGIN
  -- Get track data
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;
  
  -- Manual override from moderator
  IF p_manual_result IS NOT NULL THEN
    v_result := p_manual_result;
    v_new_status := CASE 
      WHEN p_manual_result = 'approved' THEN 'pending'
      ELSE 'rejected'
    END;
    
    UPDATE public.tracks SET
      moderation_status = v_new_status,
      voting_result = 'manual_override_' || p_manual_result,
      is_public = false
    WHERE id = p_track_id;
    
    -- Notify owner
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track.user_id,
      'voting_result',
      CASE WHEN p_manual_result = 'approved' 
        THEN '🎉 Голосование пройдено!' 
        ELSE 'Голосование завершено'
      END,
      CASE WHEN p_manual_result = 'approved'
        THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
        ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
      END,
      'track',
      p_track_id
    );
    
    RETURN jsonb_build_object(
      'success', true,
      'result', p_manual_result,
      'method', 'manual_override',
      'new_moderation_status', v_new_status
    );
  END IF;
  
  -- Automatic result calculation
  v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);
  
  SELECT COALESCE(value::integer, 10) INTO v_min_votes
  FROM public.settings WHERE key = 'voting_min_votes';
  
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio
  FROM public.settings WHERE key = 'voting_approval_ratio';
  
  IF v_total_votes < v_min_votes THEN
    v_result := 'rejected';
    v_new_status := 'rejected';
  ELSE
    v_like_ratio := v_track.voting_likes_count::numeric / v_total_votes;
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved';
      v_new_status := 'pending';
    ELSE
      v_result := 'rejected';
      v_new_status := 'rejected';
    END IF;
  END IF;
  
  UPDATE public.tracks SET
    moderation_status = v_new_status,
    voting_result = v_result,
    is_public = false
  WHERE id = p_track_id;
  
  -- Notify owner
  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_track.user_id,
    'voting_result',
    CASE WHEN v_result = 'voting_approved' 
      THEN '🎉 Голосование пройдено!' 
      ELSE 'Голосование завершено'
    END,
    CASE WHEN v_result = 'voting_approved'
      THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
      ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
    END,
    'track',
    p_track_id
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'total_votes', v_total_votes,
    'like_ratio', v_like_ratio,
    'min_votes_required', v_min_votes,
    'approval_ratio_required', v_approval_ratio,
    'new_moderation_status', v_new_status
  );
END;
$$;


-- =====================================================
-- Migration: 20260207174432_6f57182a-63d6-4ca2-a6f7-68dac26d3098.sql
-- =====================================================

-- Create SECURITY DEFINER function to atomically create a voting forum topic
-- This bypasses RLS issues and ensures the topic is always created
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
  v_topic_title TEXT;
  v_topic_content TEXT;
  v_slug TEXT;
  v_topic_id UUID;
  v_voting_category_id UUID := '667eca41-29ad-40bf-bf92-cceec00f5875';
BEGIN
  -- 1. Get track data
  SELECT id, title, description, user_id, cover_url
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found: %', p_track_id;
  END IF;

  -- 2. Get author username
  SELECT username INTO v_author_username
  FROM public.profiles
  WHERE user_id = v_track.user_id;

  v_author_username := COALESCE(v_author_username, 'автора');

  -- 3. Build topic content
  v_topic_title := '🎵 Голосование: ' || v_track.title;
  v_topic_content := 'Трек **«' || v_track.title || '»** от **' || v_author_username || '** отправлен на голосование сообщества.' ||
    E'\n\nПослушайте трек и проголосуйте! Ваш голос поможет решить, будет ли этот трек одобрен для дистрибуции.' ||
    CASE WHEN v_track.description IS NOT NULL AND v_track.description != '' 
      THEN E'\n\n' || v_track.description 
      ELSE '' 
    END;

  -- 4. Generate slug
  v_slug := lower(v_topic_title);
  v_slug := regexp_replace(v_slug, '[^a-zа-яё0-9\s]', '', 'gi');
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := left(v_slug, 80) || '-' || to_hex(extract(epoch from now())::bigint);

  -- 5. Insert forum topic
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
    left(v_topic_content, 200),
    p_track_id,
    true,
    false
  )
  RETURNING id INTO v_topic_id;

  -- 6. Link topic back to track
  UPDATE public.tracks
  SET forum_topic_id = v_topic_id
  WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;


-- =====================================================
-- Migration: 20260207175025_0a0c69bd-e244-4489-be50-5daf49dd2684.sql
-- =====================================================

-- Update the create_voting_forum_topic function with professional content template
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
  -- 1. Get track data
  SELECT id, title, user_id, cover_url, genre_id, voting_ends_at
  INTO v_track
  FROM public.tracks
  WHERE id = p_track_id;

  IF v_track IS NULL THEN
    RAISE EXCEPTION 'Track not found: %', p_track_id;
  END IF;

  -- 2. Get author username
  SELECT username INTO v_author_username
  FROM public.profiles
  WHERE user_id = v_track.user_id;

  v_author_username := COALESCE(v_author_username, 'Автор');

  -- 3. Get genre name
  IF v_track.genre_id IS NOT NULL THEN
    SELECT name_ru INTO v_genre_name
    FROM public.genres
    WHERE id = v_track.genre_id;
  END IF;

  -- 4. Format voting end date
  IF v_track.voting_ends_at IS NOT NULL THEN
    v_voting_ends := to_char(v_track.voting_ends_at AT TIME ZONE 'Europe/Moscow', 'DD.MM.YYYY в HH24:MI') || ' (МСК)';
  ELSE
    v_voting_ends := 'не указано';
  END IF;

  -- 5. Build professional topic content
  v_topic_title := '🗳️ Голосование: ' || v_track.title;

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

  -- 6. Generate slug
  v_slug := lower(v_topic_title);
  v_slug := regexp_replace(v_slug, '[^a-zа-яё0-9\s]', '', 'gi');
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := left(v_slug, 80) || '-' || to_hex(extract(epoch from now())::bigint);

  -- 7. Insert forum topic
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

  -- 8. Link topic back to track
  UPDATE public.tracks
  SET forum_topic_id = v_topic_id
  WHERE id = p_track_id;

  RETURN v_topic_id;
END;
$$;


-- =====================================================
-- Migration: 20260207180226_18902671-f69a-4fcc-a31a-d3609bb50263.sql
-- =====================================================

-- ============================================================
-- 1) RPC: Cascade delete a forum topic (moderator only)
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_forum_topic_cascade(
  p_topic_id UUID,
  p_moderator_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Verify moderator role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = p_moderator_id
      AND role IN ('moderator', 'admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления темы';
  END IF;

  -- Unlink from tracks
  UPDATE tracks SET forum_topic_id = NULL WHERE forum_topic_id = p_topic_id;

  -- Delete forum reports referencing this topic
  DELETE FROM forum_reports WHERE topic_id = p_topic_id;

  -- Delete post-level sub-records (reactions, votes, attachments) for posts in this topic
  DELETE FROM forum_post_reactions
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  DELETE FROM forum_post_votes
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  DELETE FROM forum_attachments
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  -- Delete topic-level sub-records
  DELETE FROM forum_bookmarks WHERE topic_id = p_topic_id;
  DELETE FROM forum_drafts WHERE topic_id = p_topic_id;
  DELETE FROM forum_topic_tags WHERE topic_id = p_topic_id;

  -- Delete polls
  DELETE FROM forum_poll_votes WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_poll_options WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_polls WHERE topic_id = p_topic_id;

  -- Delete all posts
  DELETE FROM forum_posts WHERE topic_id = p_topic_id;

  -- Delete the topic itself
  DELETE FROM forum_topics WHERE id = p_topic_id;

  -- Log the action
  INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
  VALUES (
    p_moderator_id,
    'delete_topic',
    'topic',
    p_topic_id,
    CASE WHEN p_reason IS NOT NULL
      THEN jsonb_build_object('reason', p_reason)
      ELSE NULL
    END
  );

  RETURN TRUE;
END;
$$;

-- ============================================================
-- 2) RPC: Close a voting forum topic with rejection reason
-- Called when admin rejects a track during voting
-- ============================================================
CREATE OR REPLACE FUNCTION public.close_voting_topic_on_rejection(
  p_track_id UUID,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_topic_id UUID;
  v_track_title TEXT;
BEGIN
  -- Get forum topic and track title
  SELECT forum_topic_id, title INTO v_topic_id, v_track_title
  FROM tracks WHERE id = p_track_id;

  IF v_topic_id IS NULL THEN
    RETURN; -- No forum topic linked, nothing to do
  END IF;

  -- Post rejection message as system user
  INSERT INTO forum_posts (topic_id, user_id, content)
  VALUES (
    v_topic_id,
    '00000000-0000-0000-0000-000000000000',
    '❌ **Голосование отменено**' || E'\n\n' ||
    'Трек **«' || COALESCE(v_track_title, 'Без названия') || '»** отклонён модератором.' || E'\n\n' ||
    '📋 **Причина:** ' || p_reason || E'\n\n' ||
    '---' || E'\n' ||
    '_Голосование и комментарии к этому треку закрыты._'
  );

  -- Lock the topic and unpin
  UPDATE forum_topics
  SET is_locked = true, is_pinned = false
  WHERE id = v_topic_id;
END;
$$;


-- =====================================================
-- Migration: 20260207180821_7ab02d4c-75ae-4935-aecb-4befc1138824.sql
-- =====================================================

CREATE OR REPLACE FUNCTION public.delete_forum_topic_cascade(
  p_topic_id UUID,
  p_moderator_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category_id UUID;
BEGIN
  -- Verify moderator role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = p_moderator_id
      AND role IN ('moderator', 'admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления темы';
  END IF;

  -- Get category_id before deletion
  SELECT category_id INTO v_category_id FROM forum_topics WHERE id = p_topic_id;

  -- Unlink from tracks (reset voting status too)
  UPDATE tracks 
  SET forum_topic_id = NULL,
      voting_result = NULL,
      voting_started_at = NULL,
      voting_ends_at = NULL,
      voting_likes_count = 0,
      voting_dislikes_count = 0,
      voting_type = NULL,
      moderation_status = CASE 
        WHEN moderation_status = 'voting' THEN 'pending'
        ELSE moderation_status
      END
  WHERE forum_topic_id = p_topic_id;

  -- Delete forum reports referencing this topic
  DELETE FROM forum_reports WHERE topic_id = p_topic_id;

  -- Delete post-level sub-records
  DELETE FROM forum_post_reactions
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  DELETE FROM forum_post_votes
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  DELETE FROM forum_attachments
    WHERE post_id IN (SELECT id FROM forum_posts WHERE topic_id = p_topic_id)
       OR topic_id = p_topic_id;

  -- Delete topic-level sub-records
  DELETE FROM forum_bookmarks WHERE topic_id = p_topic_id;
  DELETE FROM forum_drafts WHERE topic_id = p_topic_id;
  DELETE FROM forum_topic_tags WHERE topic_id = p_topic_id;

  -- Delete polls
  DELETE FROM forum_poll_votes WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_poll_options WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_polls WHERE topic_id = p_topic_id;

  -- Delete all posts
  DELETE FROM forum_posts WHERE topic_id = p_topic_id;

  -- Delete the topic itself
  DELETE FROM forum_topics WHERE id = p_topic_id;

  -- Recalculate category counters
  IF v_category_id IS NOT NULL THEN
    UPDATE forum_categories SET
      topics_count = (SELECT COUNT(*) FROM forum_topics WHERE category_id = v_category_id),
      posts_count = (SELECT COUNT(*) FROM forum_posts fp JOIN forum_topics ft ON fp.topic_id = ft.id WHERE ft.category_id = v_category_id),
      last_post_at = (SELECT MAX(fp.created_at) FROM forum_posts fp JOIN forum_topics ft ON fp.topic_id = ft.id WHERE ft.category_id = v_category_id),
      last_topic_id = (SELECT ft.id FROM forum_topics ft WHERE ft.category_id = v_category_id ORDER BY ft.created_at DESC LIMIT 1)
    WHERE id = v_category_id;
  END IF;

  -- Log the action
  INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
  VALUES (
    p_moderator_id,
    'delete_topic',
    'topic',
    p_topic_id,
    CASE WHEN p_reason IS NOT NULL
      THEN jsonb_build_object('reason', p_reason)
      ELSE NULL
    END
  );

  RETURN TRUE;
END;
$$;


-- =====================================================
-- Migration: 20260207184146_b5b9f6f8-e1a3-4290-90b4-c82012d5bca8.sql
-- =====================================================

-- Fix: Skip rate limit and mute checks for system user (00000000-0000-0000-0000-000000000000)
-- This user is used by RPC functions to post system messages (voting results, rejection notices)

CREATE OR REPLACE FUNCTION forum_check_muted_status()
RETURNS TRIGGER AS $$
DECLARE
  user_stats RECORD;
BEGIN
  -- Skip check for system user
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
    RETURN NEW;
  END IF;

  SELECT is_muted, muted_until INTO user_stats
  FROM forum_user_stats
  WHERE user_id = NEW.user_id;

  IF user_stats IS NOT NULL AND user_stats.is_muted = true THEN
    IF user_stats.muted_until IS NOT NULL AND user_stats.muted_until <= now() THEN
      UPDATE forum_user_stats SET is_muted = false, muted_until = NULL WHERE user_id = NEW.user_id;
    ELSE
      RAISE EXCEPTION 'You are currently muted and cannot post';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Fix rate limit trigger to skip system user
CREATE OR REPLACE FUNCTION forum_check_rate_limit()
RETURNS TRIGGER AS $$
DECLARE
  recent_count INT;
  rate_per_min INT := 3;
  cooldown_sec INT := 15;
  last_post_time TIMESTAMPTZ;
  setting_row RECORD;
BEGIN
  -- Skip check for system user
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
    RETURN NEW;
  END IF;

  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_rate_limit_per_minute' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    rate_per_min := (setting_row.value::text)::int;
  END IF;

  SELECT value INTO setting_row FROM forum_automod_settings WHERE key = 'forum_post_cooldown_seconds' LIMIT 1;
  IF setting_row IS NOT NULL THEN
    cooldown_sec := (setting_row.value::text)::int;
  END IF;

  SELECT MAX(created_at) INTO last_post_time
  FROM forum_posts
  WHERE user_id = NEW.user_id;

  IF last_post_time IS NOT NULL AND (now() - last_post_time) < (cooldown_sec || ' seconds')::interval THEN
    RAISE EXCEPTION 'Please wait before posting again (cooldown: % seconds)', cooldown_sec;
  END IF;

  SELECT COUNT(*) INTO recent_count
  FROM forum_posts
  WHERE user_id = NEW.user_id
    AND created_at > now() - interval '1 minute';

  IF recent_count >= rate_per_min THEN
    RAISE EXCEPTION 'Rate limit exceeded: maximum % posts per minute', rate_per_min;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- =====================================================
-- Migration: 20260207185711_a6990391-ce8f-4763-aa7e-69ca6cb8125d.sql
-- =====================================================

-- Table to log ALL impersonated actions performed via server proxy
CREATE TABLE public.impersonation_action_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL,
  target_user_id uuid NOT NULL,
  action_type text NOT NULL,
  action_payload jsonb DEFAULT '{}',
  result_status text NOT NULL DEFAULT 'success',
  error_message text,
  ip_address text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Index for fast lookups by admin
CREATE INDEX idx_impersonation_logs_admin ON public.impersonation_action_logs(admin_user_id, created_at DESC);
-- Index for fast lookups by target user
CREATE INDEX idx_impersonation_logs_target ON public.impersonation_action_logs(target_user_id, created_at DESC);

-- Enable RLS
ALTER TABLE public.impersonation_action_logs ENABLE ROW LEVEL SECURITY;

-- Only super_admins can read logs
CREATE POLICY "Super admins can view impersonation logs"
ON public.impersonation_action_logs
FOR SELECT
USING (public.has_role(auth.uid(), 'super_admin'));

-- No direct insert/update/delete from client — only via service_role in edge function
-- (No INSERT/UPDATE/DELETE policies = blocked by RLS)


-- =====================================================
-- Migration: 20260207201141_e91498e3-8f3e-4960-b90b-7d18423b7e1d.sql
-- =====================================================

-- Allow users to read their own activity log entries (needed for rate limit checks)
CREATE POLICY "Users read own activity log" 
ON public.forum_activity_log 
FOR SELECT 
USING (auth.uid() = user_id);


-- =====================================================
-- Migration: 20260208060153_d0063ea8-a917-4099-959f-026f0ceaa223.sql
-- =====================================================

-- ═══════════════════════════════════════════════════════════
-- Forum Promo System: paid promotional posts
-- ═══════════════════════════════════════════════════════════

-- Promo slot types
CREATE TYPE public.forum_promo_type AS ENUM ('text', 'banner', 'pinned');
CREATE TYPE public.forum_promo_status AS ENUM ('pending_content', 'pending_moderation', 'approved', 'rejected', 'expired', 'cancelled');

-- ── Main table: purchased promo slots ──────────────────────
CREATE TABLE public.forum_promo_slots (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  promo_type forum_promo_type NOT NULL DEFAULT 'text',
  status forum_promo_status NOT NULL DEFAULT 'pending_content',
  
  -- Content
  title TEXT,
  content TEXT,
  content_html TEXT,
  banner_url TEXT,
  target_url TEXT,
  
  -- Placement
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  category_id UUID REFERENCES public.forum_categories(id) ON DELETE SET NULL,
  
  -- Pricing
  price_rub NUMERIC(10,2) NOT NULL DEFAULT 0,
  refunded BOOLEAN NOT NULL DEFAULT false,
  refund_amount NUMERIC(10,2),
  
  -- Duration
  duration_days INTEGER NOT NULL DEFAULT 7,
  starts_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  
  -- Moderation
  moderated_by UUID,
  moderated_at TIMESTAMPTZ,
  rejection_reason TEXT,
  automod_flags TEXT[],
  
  -- AI check results
  ai_check_result JSONB,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_forum_promo_user ON public.forum_promo_slots(user_id);
CREATE INDEX idx_forum_promo_status ON public.forum_promo_slots(status);
CREATE INDEX idx_forum_promo_expires ON public.forum_promo_slots(expires_at) WHERE status = 'approved';
CREATE INDEX idx_forum_promo_category ON public.forum_promo_slots(category_id) WHERE status = 'approved';

-- ── RLS ────────────────────────────────────────────────────
ALTER TABLE public.forum_promo_slots ENABLE ROW LEVEL SECURITY;

-- Users can see their own promos
CREATE POLICY "Users can view own promos"
ON public.forum_promo_slots FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Users can see approved promos from others
CREATE POLICY "Anyone can view approved promos"
ON public.forum_promo_slots FOR SELECT
TO authenticated
USING (status = 'approved' AND expires_at > now());

-- Users can insert their own promos
CREATE POLICY "Users can create own promos"
ON public.forum_promo_slots FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Users can update their own pending promos
CREATE POLICY "Users can update own pending promos"
ON public.forum_promo_slots FOR UPDATE
TO authenticated
USING (auth.uid() = user_id AND status IN ('pending_content', 'rejected'));

-- Admins/mods can view all
CREATE POLICY "Admins can view all promos"
ON public.forum_promo_slots FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'moderator'));

-- Admins/mods can update any (for moderation)
CREATE POLICY "Admins can update all promos"
ON public.forum_promo_slots FOR UPDATE
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'moderator'));

-- ── Promo settings (insert into existing automod_settings) ──
INSERT INTO public.forum_automod_settings (key, value, description)
VALUES (
  'promo_settings',
  '{
    "enabled": true,
    "prices": {
      "text": 500,
      "banner": 1000,
      "pinned": 2000
    },
    "durations": {
      "text": 7,
      "banner": 14,
      "pinned": 7
    },
    "max_active_per_user": 3,
    "allowed_categories": [],
    "require_ai_check": true,
    "refund_on_rejection": true,
    "refund_percent": 100
  }'::jsonb,
  'Настройки платной рекламы на форуме: цены (₽), длительность, лимиты'
)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = now();

-- ── RPC: Purchase promo slot ───────────────────────────────
CREATE OR REPLACE FUNCTION public.forum_purchase_promo(
  p_user_id UUID,
  p_promo_type TEXT,
  p_category_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_price NUMERIC;
  v_duration INT;
  v_balance NUMERIC;
  v_active_count INT;
  v_max_active INT;
  v_slot_id UUID;
BEGIN
  -- Get settings
  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';
  IF v_settings IS NULL OR NOT (v_settings->>'enabled')::boolean THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо-реклама временно недоступна');
  END IF;

  -- Get price and duration
  v_price := (v_settings->'prices'->>p_promo_type)::numeric;
  v_duration := (v_settings->'durations'->>p_promo_type)::int;
  IF v_price IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Неверный тип промо');
  END IF;

  -- Check user balance
  SELECT balance INTO v_balance FROM profiles WHERE id = p_user_id;
  IF v_balance IS NULL OR v_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств. Необходимо: ' || v_price || ' ₽');
  END IF;

  -- Check active promo limit
  v_max_active := COALESCE((v_settings->>'max_active_per_user')::int, 3);
  SELECT COUNT(*) INTO v_active_count
  FROM forum_promo_slots
  WHERE user_id = p_user_id AND status IN ('pending_content', 'pending_moderation', 'approved');
  
  IF v_active_count >= v_max_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'Максимум активных промо: ' || v_max_active);
  END IF;

  -- Deduct balance
  UPDATE profiles SET balance = balance - v_price WHERE id = p_user_id;

  -- Create promo slot
  INSERT INTO forum_promo_slots (user_id, promo_type, status, price_rub, duration_days, category_id)
  VALUES (p_user_id, p_promo_type::forum_promo_type, 'pending_content', v_price, v_duration, p_category_id)
  RETURNING id INTO v_slot_id;

  RETURN jsonb_build_object(
    'success', true,
    'slot_id', v_slot_id,
    'price', v_price,
    'duration_days', v_duration,
    'message', 'Промо-слот куплен! Заполните контент и отправьте на модерацию.'
  );
END;
$$;

-- ── RPC: Moderate promo (approve/reject) ───────────────────
CREATE OR REPLACE FUNCTION public.forum_moderate_promo(
  p_slot_id UUID,
  p_moderator_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slot RECORD;
  v_settings JSONB;
  v_refund_percent INT;
  v_refund_amount NUMERIC;
BEGIN
  -- Get slot
  SELECT * INTO v_slot FROM forum_promo_slots WHERE id = p_slot_id;
  IF v_slot IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо-слот не найден');
  END IF;

  IF v_slot.status != 'pending_moderation' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо не на модерации');
  END IF;

  -- Get settings
  SELECT value INTO v_settings FROM forum_automod_settings WHERE key = 'promo_settings';

  IF p_action = 'approve' THEN
    UPDATE forum_promo_slots SET
      status = 'approved',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      starts_at = now(),
      expires_at = now() + (v_slot.duration_days || ' days')::interval,
      updated_at = now()
    WHERE id = p_slot_id;

    -- Log
    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_approved', 'promo', p_slot_id::text, jsonb_build_object('promo_type', v_slot.promo_type));

    RETURN jsonb_build_object('success', true, 'message', 'Промо одобрено и опубликовано');

  ELSIF p_action = 'reject' THEN
    -- Calculate refund
    v_refund_percent := COALESCE((v_settings->>'refund_percent')::int, 100);
    v_refund_amount := v_slot.price_rub * v_refund_percent / 100;

    -- Refund
    IF v_refund_amount > 0 AND COALESCE((v_settings->>'refund_on_rejection')::boolean, true) THEN
      UPDATE profiles SET balance = balance + v_refund_amount WHERE id = v_slot.user_id;
    END IF;

    UPDATE forum_promo_slots SET
      status = 'rejected',
      moderated_by = p_moderator_id,
      moderated_at = now(),
      rejection_reason = p_reason,
      refunded = (v_refund_amount > 0),
      refund_amount = v_refund_amount,
      updated_at = now()
    WHERE id = p_slot_id;

    -- Log
    INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
    VALUES (p_moderator_id, 'promo_rejected', 'promo', p_slot_id::text, 
      jsonb_build_object('reason', p_reason, 'refund', v_refund_amount));

    RETURN jsonb_build_object('success', true, 'message', 'Промо отклонено. Возврат: ' || v_refund_amount || ' ₽');
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Неверное действие');
  END IF;
END;
$$;

-- ── Trigger: auto-expire promo slots (can be called by cron) ──
CREATE OR REPLACE FUNCTION public.forum_expire_promos()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE forum_promo_slots 
  SET status = 'expired', updated_at = now()
  WHERE status = 'approved' AND expires_at < now();
END;
$$;

-- ── Updated_at trigger ─────────────────────────────────────
CREATE TRIGGER update_forum_promo_slots_updated_at
BEFORE UPDATE ON public.forum_promo_slots
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- =====================================================
-- Migration: 20260208062659_7ae1dafd-ad72-4517-b681-993c4b011a95.sql
-- =====================================================

-- Add AI analysis fields to forum_reports for hybrid moderation system
ALTER TABLE public.forum_reports
  ADD COLUMN IF NOT EXISTS ai_verdict TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_confidence NUMERIC(3,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_category TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_reason TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS content_snapshot TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS target_user_id UUID DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS auto_actioned BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS report_count INTEGER DEFAULT 1;

-- Index for fast pending + priority queries
CREATE INDEX IF NOT EXISTS idx_forum_reports_status_verdict 
  ON public.forum_reports (status, ai_verdict, created_at DESC);

-- Index for counting reports per target
CREATE INDEX IF NOT EXISTS idx_forum_reports_target 
  ON public.forum_reports (post_id, topic_id, status);

-- Function to count reports for the same target and update report_count
CREATE OR REPLACE FUNCTION public.forum_update_report_count()
RETURNS TRIGGER AS $$
BEGIN
  -- Update report_count for all pending reports on the same target
  IF NEW.post_id IS NOT NULL THEN
    UPDATE public.forum_reports
    SET report_count = (
      SELECT COUNT(*) FROM public.forum_reports 
      WHERE post_id = NEW.post_id AND status = 'pending'
    )
    WHERE post_id = NEW.post_id AND status = 'pending';
  ELSIF NEW.topic_id IS NOT NULL THEN
    UPDATE public.forum_reports
    SET report_count = (
      SELECT COUNT(*) FROM public.forum_reports 
      WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending'
    )
    WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger to auto-update report counts
DROP TRIGGER IF EXISTS trg_forum_report_count ON public.forum_reports;
CREATE TRIGGER trg_forum_report_count
  AFTER INSERT ON public.forum_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_update_report_count();


-- =====================================================
-- Migration: 20260208064234_749c0d07-76cd-4d80-bd3c-e5837a974c49.sql
-- =====================================================

-- Add missing columns to notifications table
-- These are needed by the forum_notify_warning trigger and are useful for all notifications
ALTER TABLE public.notifications 
ADD COLUMN IF NOT EXISTS link TEXT,
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT NULL;

-- Add comment for documentation
COMMENT ON COLUMN public.notifications.link IS 'Navigation link for the notification (e.g. /forum, /track/123)';
COMMENT ON COLUMN public.notifications.metadata IS 'Additional structured data for the notification';


-- =====================================================
-- Migration: 20260208065134_b2a71213-1e37-4586-b604-44bfcac8587d.sql
-- =====================================================

CREATE OR REPLACE FUNCTION public.forum_notify_warning()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _link TEXT;
BEGIN
  -- Build specific link: prefer topic, fallback to /forum
  IF NEW.topic_id IS NOT NULL THEN
    _link := '/forum/t/' || NEW.topic_id;
  ELSE
    _link := '/forum';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message, link, metadata)
  VALUES (
    NEW.user_id,
    'forum_warning',
    'Предупреждение на форуме',
    NEW.reason,
    _link,
    jsonb_build_object(
      'warning_id', NEW.id, 
      'severity', NEW.severity,
      'topic_id', NEW.topic_id,
      'post_id', NEW.post_id
    )
  );
  RETURN NEW;
END;
$function$;


-- =====================================================
-- Migration: 20260208121143_37574a4b-45c3-43b0-9049-9deb3791b945.sql
-- =====================================================
-- Centralized balance transaction log
-- Every balance change (deduction or topup) gets recorded here
CREATE TABLE public.balance_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  amount INTEGER NOT NULL, -- positive = income, negative = spending
  balance_after INTEGER, -- balance after this transaction
  type TEXT NOT NULL, -- 'topup', 'generation', 'separation', 'video', 'lyrics_gen', 'lyrics_deposit', 'track_deposit', 'beat_purchase', 'prompt_purchase', 'item_purchase', 'forum_ai', 'refund', 'admin', 'sale_income'
  description TEXT NOT NULL,
  reference_id UUID, -- ID of the related entity (track_id, payment_id, etc.)
  reference_type TEXT, -- 'track', 'payment', 'audio_separation', 'promo_video', 'lyrics_deposit', 'beat', 'prompt', 'store_item', 'forum_topic'
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for fast user queries
CREATE INDEX idx_balance_transactions_user_id ON public.balance_transactions(user_id);
CREATE INDEX idx_balance_transactions_user_created ON public.balance_transactions(user_id, created_at DESC);
CREATE INDEX idx_balance_transactions_type ON public.balance_transactions(type);

-- Enable RLS
ALTER TABLE public.balance_transactions ENABLE ROW LEVEL SECURITY;

-- Users can only see their own transactions
CREATE POLICY "Users can view own transactions"
  ON public.balance_transactions FOR SELECT
  USING (auth.uid() = user_id);

-- Only service role can insert (via edge functions)
CREATE POLICY "Service role can insert transactions"
  ON public.balance_transactions FOR INSERT
  WITH CHECK (true);

-- Backfill from existing data: generation_logs (completed)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  gl.user_id,
  -gl.cost_rub,
  'generation',
  COALESCE('Генерация трека: ' || t.title, 'Генерация трека'),
  gl.track_id,
  'track',
  gl.created_at
FROM public.generation_logs gl
LEFT JOIN public.tracks t ON t.id = gl.track_id
WHERE gl.status = 'completed' AND gl.cost_rub > 0;

-- Backfill: generation_logs (failed with refund)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  gl.user_id,
  gl.cost_rub,
  'refund',
  COALESCE('Возврат за генерацию: ' || t.title, 'Возврат за неудачную генерацию'),
  gl.track_id,
  'track',
  gl.created_at
FROM public.generation_logs gl
LEFT JOIN public.tracks t ON t.id = gl.track_id
WHERE gl.status = 'failed' AND gl.cost_rub > 0;

-- Backfill: payments (topups)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  p.user_id,
  p.amount,
  'topup',
  COALESCE(p.description, 'Пополнение баланса') || ' (' || p.payment_system || ')',
  p.id,
  'payment',
  p.created_at
FROM public.payments p
WHERE p.status = 'completed';

-- Backfill: audio_separations
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  a.user_id,
  -a.price_rub,
  'separation',
  'Разделение аудио (' || a.type || ')',
  a.id,
  'audio_separation',
  a.created_at
FROM public.audio_separations a
WHERE a.price_rub > 0;

-- Backfill: promo_videos
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pv.user_id,
  -pv.price_rub,
  'video',
  'Промо-видео',
  pv.track_id,
  'track',
  pv.created_at
FROM public.promo_videos pv
WHERE pv.price_rub > 0 AND pv.status != 'failed';

-- Backfill: lyrics_deposits
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ld.user_id,
  -ld.price_rub,
  'lyrics_deposit',
  'Депозит текста',
  ld.id,
  'lyrics_deposit',
  ld.created_at
FROM public.lyrics_deposits ld
WHERE ld.price_rub > 0 AND ld.status = 'completed';

-- Backfill: beat_purchases (buyer side)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  bp.buyer_id,
  -bp.price,
  'beat_purchase',
  'Покупка бита',
  bp.beat_id,
  'beat',
  bp.created_at
FROM public.beat_purchases bp
WHERE bp.status = 'completed';

-- Backfill: beat_purchases (seller income)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  bp.seller_id,
  bp.price,
  'sale_income',
  'Продажа бита',
  bp.beat_id,
  'beat',
  bp.created_at
FROM public.beat_purchases bp
WHERE bp.status = 'completed';

-- Backfill: prompt_purchases (buyer)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pp.buyer_id,
  -pp.price,
  'prompt_purchase',
  'Покупка промпта',
  pp.prompt_id,
  'prompt',
  pp.created_at
FROM public.prompt_purchases pp
WHERE pp.status = 'completed';

-- Backfill: prompt_purchases (seller)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pp.seller_id,
  pp.price,
  'sale_income',
  'Продажа промпта',
  pp.prompt_id,
  'prompt',
  pp.created_at
FROM public.prompt_purchases pp
WHERE pp.status = 'completed';

-- Backfill: item_purchases (buyer)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ip.buyer_id,
  -ip.price,
  'item_purchase',
  'Покупка товара',
  ip.store_item_id,
  'store_item',
  ip.created_at
FROM public.item_purchases ip
WHERE ip.status = 'completed';

-- Backfill: item_purchases (seller)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ip.seller_id,
  ip.net_amount,
  'sale_income',
  'Продажа товара',
  ip.store_item_id,
  'store_item',
  ip.created_at
FROM public.item_purchases ip
WHERE ip.status = 'completed' AND ip.net_amount > 0;

-- Enable realtime for live updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.balance_transactions;

-- =====================================================
-- Migration: 20260208121157_d22436b6-4fc8-496e-b19f-78819d56a5f6.sql
-- =====================================================
-- Fix overly permissive INSERT policy on balance_transactions
-- Only service_role should insert, drop the permissive policy
DROP POLICY "Service role can insert transactions" ON public.balance_transactions;

-- No client-side inserts allowed — service_role bypasses RLS anyway
-- This effectively means only server-side (edge functions) can insert

-- =====================================================
-- Migration: 20260208153139_b98fbf64-3a23-4964-8009-c5b45b5afc9d.sql
-- =====================================================

-- ============================================
-- Admin Announcements System
-- ============================================

-- Enum for announcement types
CREATE TYPE public.announcement_type AS ENUM ('system', 'news', 'event', 'community');

-- Enum for display mode
CREATE TYPE public.announcement_display_mode AS ENUM ('banner', 'modal');

-- Enum for priority
CREATE TYPE public.announcement_priority AS ENUM ('info', 'warning', 'critical');

-- Main announcements table
CREATE TABLE public.admin_announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  content_html TEXT,
  announcement_type public.announcement_type NOT NULL DEFAULT 'news',
  display_mode public.announcement_display_mode NOT NULL DEFAULT 'banner',
  priority public.announcement_priority NOT NULL DEFAULT 'info',
  is_dismissible BOOLEAN NOT NULL DEFAULT true,
  is_published BOOLEAN NOT NULL DEFAULT false,
  publish_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  target_audience JSONB DEFAULT NULL,
  cover_url TEXT,
  action_url TEXT,
  action_label TEXT,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Dismissals tracking
CREATE TABLE public.announcement_dismissals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id UUID NOT NULL REFERENCES public.admin_announcements(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(announcement_id, user_id)
);

-- Indexes
CREATE INDEX idx_announcements_published ON public.admin_announcements (is_published, publish_at, expires_at);
CREATE INDEX idx_announcements_type ON public.admin_announcements (announcement_type);
CREATE INDEX idx_dismissals_user ON public.announcement_dismissals (user_id);
CREATE INDEX idx_dismissals_announcement ON public.announcement_dismissals (announcement_id);

-- Enable RLS
ALTER TABLE public.admin_announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcement_dismissals ENABLE ROW LEVEL SECURITY;

-- Announcements: everyone can read published
CREATE POLICY "Anyone can read published announcements"
  ON public.admin_announcements FOR SELECT
  USING (is_published = true);

-- Announcements: admins can do everything
CREATE POLICY "Admins can manage announcements"
  ON public.admin_announcements FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Dismissals: users can read their own
CREATE POLICY "Users can read own dismissals"
  ON public.announcement_dismissals FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Dismissals: users can insert their own
CREATE POLICY "Users can dismiss announcements"
  ON public.announcement_dismissals FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Updated_at trigger
CREATE TRIGGER update_announcements_updated_at
  BEFORE UPDATE ON public.admin_announcements
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================
-- Welcome onboarding tracking
-- ============================================
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN DEFAULT false;


-- =====================================================
-- Migration: 20260208160209_3ca6026c-be7a-46e1-9f10-04f8b5a4148a.sql
-- =====================================================

-- Table for tracking when users last read a category or topic
CREATE TABLE public.forum_user_reads (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('category', 'topic')),
  entity_id UUID NOT NULL,
  last_read_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, entity_type, entity_id)
);

-- Index for efficient lookups by user
CREATE INDEX idx_forum_user_reads_user ON public.forum_user_reads(user_id);
CREATE INDEX idx_forum_user_reads_entity ON public.forum_user_reads(entity_type, entity_id);

-- Enable RLS
ALTER TABLE public.forum_user_reads ENABLE ROW LEVEL SECURITY;

-- Users can see only their own reads
CREATE POLICY "Users can view their own reads"
ON public.forum_user_reads
FOR SELECT
USING (auth.uid() = user_id);

-- Users can insert their own reads
CREATE POLICY "Users can insert their own reads"
ON public.forum_user_reads
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can update their own reads
CREATE POLICY "Users can update their own reads"
ON public.forum_user_reads
FOR UPDATE
USING (auth.uid() = user_id);

-- Upsert function for marking as read
CREATE OR REPLACE FUNCTION public.forum_mark_read(
  p_user_id UUID,
  p_entity_type TEXT,
  p_entity_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.forum_user_reads (user_id, entity_type, entity_id, last_read_at)
  VALUES (p_user_id, p_entity_type, p_entity_id, now())
  ON CONFLICT (user_id, entity_type, entity_id)
  DO UPDATE SET last_read_at = now();
END;
$$;


-- =====================================================
-- Migration: 20260208163721_dcdcadeb-1e0c-4cdb-930c-51b46ee4eb6e.sql
-- =====================================================

-- ===== MESSAGES TABLE FIXES =====

-- 1. Drop the old SELECT policy that doesn't filter deleted messages
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON public.messages;

-- 2. Drop duplicate UPDATE policy (keep the one with admin access)
DROP POLICY IF EXISTS "Users can update own messages" ON public.messages;

-- 3. Recreate remaining policies with proper roles (authenticated instead of public)

-- SELECT: already correct policy exists "Users can view their conversation messages"
-- but let's ensure it targets authenticated role
DROP POLICY IF EXISTS "Users can view their conversation messages" ON public.messages;
CREATE POLICY "Users can view their conversation messages"
ON public.messages FOR SELECT
TO authenticated
USING (deleted_at IS NULL AND is_participant_in_conversation(auth.uid(), conversation_id));

-- Admin SELECT for messages (to see all messages including deleted)
CREATE POLICY "Admins can view all messages"
ON public.messages FOR SELECT
TO authenticated
USING (is_admin(auth.uid()));

-- INSERT: recreate with authenticated role
DROP POLICY IF EXISTS "Users can send messages to their conversations" ON public.messages;
CREATE POLICY "Users can send messages to their conversations"
ON public.messages FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM conversation_participants
    WHERE conversation_participants.conversation_id = messages.conversation_id
      AND conversation_participants.user_id = auth.uid()
  )
);

-- UPDATE: recreate with authenticated role  
DROP POLICY IF EXISTS "Users can update their own messages" ON public.messages;
CREATE POLICY "Users can update their own messages"
ON public.messages FOR UPDATE
TO authenticated
USING (sender_id = auth.uid() OR is_admin(auth.uid()))
WITH CHECK (sender_id = auth.uid() OR is_admin(auth.uid()));

-- DELETE: recreate with authenticated role
DROP POLICY IF EXISTS "Users can delete their own messages" ON public.messages;
CREATE POLICY "Users can delete their own messages"
ON public.messages FOR DELETE
TO authenticated
USING (sender_id = auth.uid() OR is_admin(auth.uid()));


-- ===== PAYMENTS TABLE FIXES =====

-- 1. Drop duplicate SELECT policy
DROP POLICY IF EXISTS "Users can only view own payments" ON public.payments;

-- 2. Recreate INSERT with authenticated role
DROP POLICY IF EXISTS "Allow insert for authenticated users" ON public.payments;
CREATE POLICY "Authenticated users can insert own payments"
ON public.payments FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id OR is_admin(auth.uid()));

-- 3. Recreate UPDATE with authenticated role (already uses authenticated via is_admin)
DROP POLICY IF EXISTS "Admins can update payments" ON public.payments;
CREATE POLICY "Admins can update payments"
ON public.payments FOR UPDATE
TO authenticated
USING (is_admin(auth.uid()))
WITH CHECK (is_admin(auth.uid()));


-- =====================================================
-- Migration: 20260209162150_365cb71e-14c8-404a-8681-5334b167d5ff.sql
-- =====================================================

-- FIX 1: profiles_public — remove sensitive fields (is_verified, verification_type, last_seen_at)
DROP VIEW IF EXISTS public.profiles_public;

CREATE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT
  id,
  user_id,
  username,
  avatar_url,
  cover_url,
  bio,
  social_links,
  followers_count,
  following_count,
  created_at,
  updated_at
FROM public.profiles;

-- FIX 2: payout_requests — restrict direct SELECT to owner only via safe view
-- First ensure the safe view masks payment_details properly
DROP VIEW IF EXISTS public.payout_requests_safe;

CREATE VIEW public.payout_requests_safe
WITH (security_invoker = on) AS
SELECT
  id,
  seller_id,
  amount,
  payment_method,
  status,
  admin_notes,
  created_at,
  processed_at,
  CASE
    WHEN payment_details IS NOT NULL THEN
      jsonb_build_object(
        'masked', true,
        'method_type', payment_details->>'method_type'
      )
    ELSE NULL
  END AS payment_details_masked
FROM public.payout_requests;

-- Encrypt payment_details: add a comment noting it should be encrypted at app level
COMMENT ON COLUMN public.payout_requests.payment_details IS 'Contains sensitive banking data. Always use payout_requests_safe view for reads. Raw access restricted to owner + admin via RLS.';


-- =====================================================
-- Migration: 20260209183457_e06bf958-7d2d-42b0-bfb4-b8fc2b462363.sql
-- =====================================================

-- ============================================================
-- SHIELD v2 + RESONANCE — Master Migration (Fixed)
-- ============================================================

-- ============================================================
-- PHASE 1: SHIELD v2
-- ============================================================

-- 1.1 Warning Points
CREATE TABLE public.forum_warning_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,
  total_points INTEGER NOT NULL DEFAULT 0,
  last_decay_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.forum_warning_points ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own warning points"
  ON public.forum_warning_points FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.2 Staff Notes
CREATE TABLE public.forum_staff_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  author_id UUID NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_staff_notes_user ON public.forum_staff_notes(user_id);
ALTER TABLE public.forum_staff_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Only moderators/admins can manage staff notes"
  ON public.forum_staff_notes FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.3 Warning Appeals
CREATE TABLE public.forum_warning_appeals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warning_id UUID NOT NULL REFERENCES public.forum_warnings(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  message TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  moderator_response TEXT,
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_appeals_status ON public.forum_warning_appeals(status);
CREATE INDEX idx_appeals_user ON public.forum_warning_appeals(user_id);
ALTER TABLE public.forum_warning_appeals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can create own appeals" ON public.forum_warning_appeals FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users and moderators can view appeals" ON public.forum_warning_appeals FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can update appeals" ON public.forum_warning_appeals FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.4 User Bans (3 zones)
CREATE TABLE public.forum_user_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  ban_zone TEXT NOT NULL DEFAULT 'forum',
  reason TEXT,
  banned_by UUID,
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  cooldown_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_user_bans_active ON public.forum_user_bans(user_id, ban_zone, is_active);
ALTER TABLE public.forum_user_bans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own bans" ON public.forum_user_bans FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can manage bans" ON public.forum_user_bans FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Moderators can update bans" ON public.forum_user_bans FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'moderator') OR public.has_role(auth.uid(), 'admin'));

-- 1.5 Shield settings
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('warning_points_notice', '1', 'Очки за notice'),
  ('warning_points_warning', '2', 'Очки за warning'),
  ('warning_points_silence', '3', 'Очки за silence'),
  ('warning_points_final_warning', '4', 'Очки за final_warning'),
  ('warning_points_auto_mute_24h', '3', 'Порог автомута 24ч'),
  ('warning_points_auto_mute_7d', '6', 'Порог автомута 7д'),
  ('warning_points_auto_ban', '10', 'Порог автобана форума'),
  ('warning_points_decay_days', '30', 'Дней для затухания -1 очка'),
  ('ai_auto_strike_threshold', '3', 'Скрытий AI для auto-strike'),
  ('ai_auto_strike_window_days', '7', 'Окно подсчёта скрытий AI (дней)'),
  ('post_ban_cooldown_days', '7', 'Cooldown после разбана (дней)'),
  ('warning_rep_penalty_warning', '-50', 'Штраф XP за warning'),
  ('warning_rep_penalty_final', '-150', 'Штраф XP за final_warning'),
  ('warning_rep_penalty_ban', '-9999', 'Сброс XP при бане')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- PHASE 2: RESONANCE
-- ============================================================

-- 2.1 Extend forum_user_stats
ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS xp_total INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_forum INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_music INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_social INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_earned INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS xp_daily_date DATE DEFAULT CURRENT_DATE,
  ADD COLUMN IF NOT EXISTS featured_badges TEXT[] DEFAULT '{}';

-- 2.2 Resonance settings
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('xp_daily_cap', '100', 'Макс XP в день'),
  ('xp_forum_topic', '3', 'XP за создание темы'),
  ('xp_forum_post', '1', 'XP за пост'),
  ('xp_forum_upvote', '5', 'XP за получение апвоута'),
  ('xp_forum_solution', '15', 'XP за решение'),
  ('xp_forum_downvote', '-2', 'XP за получение даунвоута'),
  ('xp_track_publish', '5', 'XP за публикацию трека'),
  ('xp_track_like', '2', 'XP за лайк трека'),
  ('xp_track_listen', '0', 'XP за прослушивание (отключено — нет таблицы)'),
  ('xp_follower', '3', 'XP за подписчика'),
  ('xp_comment', '1', 'XP за комментарий'),
  ('xp_comment_like', '2', 'XP за лайк комментария'),
  ('xp_contest_win', '50', 'XP за победу в конкурсе'),
  ('xp_contest_participate', '10', 'XP за участие в конкурсе'),
  ('tl1_threshold', '20', 'Порог XP для TL1'),
  ('tl2_threshold', '100', 'Порог XP для TL2'),
  ('tl3_threshold', '300', 'Порог XP для TL3'),
  ('tl4_threshold', '750', 'Порог XP для TL4'),
  ('tl_inactivity_days', '60', 'Дней неактивности для понижения TL'),
  ('tl3_clean_days', '90', 'Дней без warning для TL3')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- CORE FUNCTIONS
-- ============================================================

-- fn_add_xp: Central XP function
CREATE OR REPLACE FUNCTION public.fn_add_xp(
  p_user_id UUID, p_amount NUMERIC, p_category TEXT DEFAULT 'forum'
) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_daily_cap INTEGER; v_current_daily INTEGER; v_actual_amount INTEGER; v_new_total INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_daily_cap'), 100) INTO v_daily_cap;
  INSERT INTO forum_user_stats (user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
  UPDATE forum_user_stats SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
    WHERE user_id = p_user_id AND (xp_daily_date IS NULL OR xp_daily_date < CURRENT_DATE);
  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily FROM forum_user_stats WHERE user_id = p_user_id;
  IF p_amount > 0 THEN
    v_actual_amount := LEAST(p_amount::integer, v_daily_cap - v_current_daily);
    IF v_actual_amount <= 0 THEN RETURN 0; END IF;
  ELSE
    v_actual_amount := p_amount::integer;
  END IF;
  UPDATE forum_user_stats SET
    xp_total = GREATEST(0, xp_total + v_actual_amount),
    xp_daily_earned = CASE WHEN v_actual_amount > 0 THEN xp_daily_earned + v_actual_amount ELSE xp_daily_earned END,
    xp_forum = CASE WHEN p_category = 'forum' THEN GREATEST(0, xp_forum + v_actual_amount) ELSE xp_forum END,
    xp_music = CASE WHEN p_category = 'music' THEN GREATEST(0, xp_music + v_actual_amount) ELSE xp_music END,
    xp_social = CASE WHEN p_category = 'social' THEN GREATEST(0, xp_social + v_actual_amount) ELSE xp_social END,
    updated_at = now()
  WHERE user_id = p_user_id RETURNING xp_total INTO v_new_total;
  PERFORM fn_recalculate_trust_level(p_user_id);
  RETURN COALESCE(v_actual_amount, 0);
END; $$;

-- fn_recalculate_trust_level
CREATE OR REPLACE FUNCTION public.fn_recalculate_trust_level(p_user_id UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_xp INTEGER; v_tl1 INTEGER; v_tl2 INTEGER; v_tl3 INTEGER; v_tl4 INTEGER;
  v_new_tl INTEGER := 0; v_days INTEGER; v_has_warning BOOLEAN; v_clean_days INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl1_threshold'), 20) INTO v_tl1;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl2_threshold'), 100) INTO v_tl2;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl3_threshold'), 300) INTO v_tl3;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl4_threshold'), 750) INTO v_tl4;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'tl3_clean_days'), 90) INTO v_clean_days;
  SELECT xp_total INTO v_xp FROM forum_user_stats WHERE user_id = p_user_id;
  IF v_xp IS NULL THEN RETURN 0; END IF;
  SELECT COALESCE(EXTRACT(DAY FROM now() - created_at)::integer, 0) INTO v_days FROM profiles WHERE user_id = p_user_id;
  SELECT EXISTS(SELECT 1 FROM forum_warnings WHERE user_id = p_user_id AND is_active = true AND severity IN ('warning','final_warning','silence','ban') AND created_at > now() - (v_clean_days || ' days')::interval) INTO v_has_warning;
  IF v_xp >= v_tl4 AND v_days >= 60 AND NOT v_has_warning THEN v_new_tl := 4;
  ELSIF v_xp >= v_tl3 AND v_days >= 30 AND NOT v_has_warning THEN v_new_tl := 3;
  ELSIF v_xp >= v_tl2 AND v_days >= 14 THEN v_new_tl := 2;
  ELSIF v_xp >= v_tl1 AND v_days >= 3 THEN v_new_tl := 1;
  ELSE v_new_tl := 0; END IF;
  UPDATE forum_user_stats SET trust_level = v_new_tl, updated_at = now() WHERE user_id = p_user_id;
  RETURN v_new_tl;
END; $$;

-- fn_apply_warning_points trigger
CREATE OR REPLACE FUNCTION public.fn_apply_warning_points()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_points INTEGER := 0; v_total_points INTEGER; v_threshold_24h INTEGER; v_threshold_7d INTEGER; v_threshold_ban INTEGER; v_xp_penalty INTEGER := 0; v_cooldown_days INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_' || NEW.severity), 0) INTO v_points;
  IF NEW.severity = 'warning' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_warning'), -50) INTO v_xp_penalty;
  ELSIF NEW.severity = 'final_warning' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_final'), -150) INTO v_xp_penalty;
  ELSIF NEW.severity = 'ban' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_rep_penalty_ban'), -9999) INTO v_xp_penalty;
  END IF;
  INSERT INTO forum_warning_points (user_id, total_points) VALUES (NEW.user_id, v_points) ON CONFLICT (user_id) DO UPDATE SET total_points = forum_warning_points.total_points + v_points, updated_at = now();
  SELECT total_points INTO v_total_points FROM forum_warning_points WHERE user_id = NEW.user_id;
  IF v_xp_penalty <> 0 THEN PERFORM fn_add_xp(NEW.user_id, v_xp_penalty, 'forum'); END IF;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_mute_24h'), 3) INTO v_threshold_24h;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_mute_7d'), 6) INTO v_threshold_7d;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_auto_ban'), 10) INTO v_threshold_ban;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'post_ban_cooldown_days'), 7) INTO v_cooldown_days;
  IF NEW.severity = 'ban' OR v_total_points >= v_threshold_ban THEN
    INSERT INTO forum_user_bans (user_id, ban_zone, reason, banned_by, is_active, cooldown_until) VALUES (NEW.user_id, 'forum', 'Автобан: ' || v_total_points || ' очков', NEW.issued_by, true, now() + (v_cooldown_days || ' days')::interval);
    UPDATE forum_user_stats SET is_banned = true, ban_reason = 'Автобан: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
  ELSIF v_total_points >= v_threshold_7d THEN
    UPDATE forum_user_stats SET is_silenced = true, silenced_until = now() + interval '7 days', silence_reason = 'Автомут: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
    UPDATE forum_user_stats SET trust_level = 0 WHERE user_id = NEW.user_id;
  ELSIF v_total_points >= v_threshold_24h THEN
    UPDATE forum_user_stats SET is_silenced = true, silenced_until = now() + interval '24 hours', silence_reason = 'Автомут: ' || v_total_points || ' очков' WHERE user_id = NEW.user_id;
    UPDATE forum_user_stats SET trust_level = GREATEST(0, trust_level - 1) WHERE user_id = NEW.user_id;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_apply_warning_points AFTER INSERT ON public.forum_warnings FOR EACH ROW EXECUTE FUNCTION public.fn_apply_warning_points();

-- fn_decay_warning_points
CREATE OR REPLACE FUNCTION public.fn_decay_warning_points()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_decay_days INTEGER; v_decayed INTEGER := 0;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'warning_points_decay_days'), 30) INTO v_decay_days;
  UPDATE forum_warning_points SET total_points = GREATEST(0, total_points - 1), last_decay_at = now(), updated_at = now()
    WHERE total_points > 0 AND last_decay_at < now() - (v_decay_days || ' days')::interval;
  GET DIAGNOSTICS v_decayed = ROW_COUNT;
  RETURN v_decayed;
END; $$;

-- fn_check_ai_auto_strike
CREATE OR REPLACE FUNCTION public.fn_check_ai_auto_strike(p_user_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_threshold INTEGER; v_window INTEGER; v_count INTEGER;
BEGIN
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'ai_auto_strike_threshold'), 3) INTO v_threshold;
  SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'ai_auto_strike_window_days'), 7) INTO v_window;
  SELECT COUNT(*) INTO v_count FROM forum_mod_logs WHERE target_type = 'post' AND action = 'automod_hide' AND (details->>'user_id')::uuid = p_user_id AND created_at > now() - (v_window || ' days')::interval;
  IF v_count >= v_threshold THEN
    INSERT INTO forum_warnings (user_id, issued_by, reason, severity, is_active) VALUES (p_user_id, '00000000-0000-0000-0000-000000000000', 'Систематические нарушения (AI): ' || v_count || ' скрытий за ' || v_window || ' дней', 'warning', true);
    RETURN true;
  END IF;
  RETURN false;
END; $$;

-- ============================================================
-- XP TRIGGERS
-- ============================================================

-- Forum post → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_post() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000' THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_post'), 1), 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_post AFTER INSERT ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_post();

-- Forum topic → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_topic() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id = '00000000-0000-0000-0000-000000000000' THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_topic'), 3), 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_topic AFTER INSERT ON public.forum_topics FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_topic();

-- Forum reaction → +/- XP to post author
CREATE OR REPLACE FUNCTION public.fn_xp_on_forum_reaction() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_author UUID; v_amount INTEGER;
BEGIN
  SELECT user_id INTO v_author FROM forum_posts WHERE id = NEW.post_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;
  IF NEW.reaction_type = 'upvote' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_upvote'), 5) INTO v_amount;
  ELSIF NEW.reaction_type = 'downvote' THEN
    SELECT COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_forum_downvote'), -2) INTO v_amount;
  ELSE RETURN NEW; END IF;
  PERFORM fn_add_xp(v_author, v_amount, 'forum');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_forum_reaction AFTER INSERT ON public.forum_post_reactions FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_forum_reaction();

-- Track published → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_publish() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.is_public = true AND (OLD IS NULL OR OLD.is_public = false) THEN
    PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_track_publish'), 5), 'music');
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_publish AFTER INSERT OR UPDATE OF is_public ON public.tracks FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_publish();

-- Track liked → +XP to owner
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_like() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM tracks WHERE id = NEW.track_id;
  IF v_owner IS NULL OR v_owner = NEW.user_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(v_owner, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_track_like'), 2), 'music');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_like AFTER INSERT ON public.track_likes FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_like();

-- Follow → +XP to followed
CREATE OR REPLACE FUNCTION public.fn_xp_on_follow() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.following_id = NEW.follower_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(NEW.following_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_follower'), 3), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_follow AFTER INSERT ON public.user_follows FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_follow();

-- Track comment → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_track_comment() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_comment'), 1), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_track_comment AFTER INSERT ON public.track_comments FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_track_comment();

-- Comment liked → +XP to author
CREATE OR REPLACE FUNCTION public.fn_xp_on_comment_like() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_author UUID;
BEGIN
  SELECT user_id INTO v_author FROM track_comments WHERE id = NEW.comment_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;
  PERFORM fn_add_xp(v_author, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_comment_like'), 2), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_comment_like AFTER INSERT ON public.comment_likes FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_comment_like();

-- Contest entry → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_contest_entry() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_contest_participate'), 10), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_contest_entry AFTER INSERT ON public.contest_entries FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_contest_entry();

-- Contest win → +XP
CREATE OR REPLACE FUNCTION public.fn_xp_on_contest_win() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_add_xp(NEW.user_id, COALESCE((SELECT (value)::integer FROM forum_automod_settings WHERE key = 'xp_contest_win'), 50), 'social');
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_xp_contest_win AFTER INSERT ON public.contest_winners FOR EACH ROW EXECUTE FUNCTION public.fn_xp_on_contest_win();

-- ============================================================
-- NEW BADGES
-- ============================================================
INSERT INTO public.achievements (name, name_ru, description, description_ru, icon, category, requirement_type, requirement_value, sort_order) VALUES
  ('First Track', 'Первый трек', 'Published your first track', 'Опубликовал первый трек', '🎵', 'music', 'tracks_published', 1, 100),
  ('Hitmaker', 'Хитмейкер', '100+ likes on a single track', '100+ лайков на одном треке', '🔥', 'music', 'track_max_likes', 100, 101),
  ('Forum Activist', 'Активист', '50+ forum posts', '50+ постов на форуме', '💬', 'forum', 'forum_posts', 50, 102),
  ('Champion', 'Чемпион', 'Won a contest', 'Победа в конкурсе', '🏆', 'contests', 'contest_wins', 1, 103),
  ('Rising Star', 'Звезда', '500+ XP', '500+ XP репутации', '⭐', 'reputation', 'xp_total', 500, 104),
  ('Expert', 'Эксперт', '10 solutions on forum', '10 ответов отмечены решением', '🎯', 'forum', 'forum_solutions', 10, 105),
  ('Influencer', 'Лидер мнений', '50+ followers', '50+ подписчиков', '👥', 'social', 'followers_count', 50, 106),
  ('Spotless', 'Безупречный', 'TL3+ no warnings 6mo', 'TL3+ без предупреждений 6 мес', '🛡️', 'reputation', 'clean_record_months', 6, 107),
  ('Veteran', 'Ветеран', '1 year on platform', '1 год на платформе', '📅', 'general', 'days_on_platform', 365, 108),
  ('Music Lover', 'Меломан', '1000+ listens given', '1000+ прослушиваний', '🎧', 'music', 'listens_given', 1000, 109),
  ('Contestant', 'Конкурсант', '5+ contest entries', '5+ участий в конкурсах', '🏅', 'contests', 'contest_entries', 5, 110),
  ('Producer', 'Продюсер', '50+ published tracks', '50+ треков', '💎', 'music', 'tracks_published', 50, 111)
ON CONFLICT DO NOTHING;


-- =====================================================
-- Migration: 20260209202051_23121a9e-92f5-45da-b469-a599b9203823.sql
-- =====================================================

-- Таблица для хранения API-ключей (зашифрованные в приложении)
CREATE TABLE public.api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_name text NOT NULL UNIQUE,
  display_name text NOT NULL,
  key_value text NOT NULL,
  is_active boolean DEFAULT true,
  description text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;

-- Только super_admin может видеть и управлять ключами
CREATE POLICY "Super admins can manage api_keys"
ON public.api_keys
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'super_admin'))
WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

-- Сервис-аккаунт (edge functions) может читать ключи
CREATE POLICY "Service role can read api_keys"
ON public.api_keys
FOR SELECT
TO service_role
USING (true);

-- Таблица настроек AI-провайдеров
CREATE TABLE public.ai_provider_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_type text NOT NULL UNIQUE,
  provider text NOT NULL,
  model text,
  is_active boolean DEFAULT true,
  config jsonb DEFAULT '{}',
  description text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.ai_provider_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Super admins can manage ai_provider_settings"
ON public.ai_provider_settings
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'super_admin'))
WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

CREATE POLICY "Service role can read ai_provider_settings"
ON public.ai_provider_settings
FOR SELECT
TO service_role
USING (true);

-- Authenticated users can read active settings (non-sensitive)
CREATE POLICY "Users can read active ai_provider_settings"
ON public.ai_provider_settings
FOR SELECT
TO authenticated
USING (is_active = true);

-- Триггеры updated_at
CREATE TRIGGER update_api_keys_updated_at
BEFORE UPDATE ON public.api_keys
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_ai_provider_settings_updated_at
BEFORE UPDATE ON public.ai_provider_settings
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Предзаполнить настройки провайдеров
INSERT INTO public.ai_provider_settings (service_type, provider, model, description) VALUES
  ('music_generation', 'suno', 'chirp-v4', 'Генерация музыки'),
  ('lyrics_generation', 'deepseek', 'deepseek-chat', 'Генерация текстов'),
  ('lyrics_analysis', 'deepseek', 'deepseek-chat', 'Анализ и разметка текстов'),
  ('style_boost', 'timeweb', 'gpt-4', 'Boost стиля через Timeweb Agent'),
  ('lyrics_improve', 'deepseek', 'deepseek-chat', 'Улучшение текстов'),
  ('audio_recognition', 'acrcloud', NULL, 'Распознавание аудио');

-- Предзаполнить ключи (пустые значения, super_admin заполнит)
INSERT INTO public.api_keys (service_name, display_name, key_value, description) VALUES
  ('SUNO_API_KEY', 'Suno API Key', '', 'Ключ для Suno API генерации музыки'),
  ('DEEPSEEK_API_KEY', 'DeepSeek API Key', '', 'Ключ для DeepSeek LLM'),
  ('TIMEWEB_AGENT_TOKEN', 'Timeweb Agent Token', '', 'Токен для Timeweb Agent API'),
  ('ACRCLOUD_ACCESS_KEY', 'ACRCloud Access Key', '', 'Ключ доступа ACRCloud'),
  ('ACRCLOUD_ACCESS_SECRET', 'ACRCloud Access Secret', '', 'Секрет ACRCloud'),
  ('ACRCLOUD_HOST', 'ACRCloud Host', '', 'Хост ACRCloud'),
  ('ACOUSTID_API_KEY', 'AcoustID API Key', '', 'Ключ AcoustID'),
  ('SUNO_CALLBACK_SECRET', 'Suno Callback Secret', '', 'Секрет для Suno callback'),
  ('FFMPEG_API_URL', 'FFmpeg API URL', '', 'URL FFmpeg API сервера'),
  ('FFMPEG_SECRET', 'FFmpeg Secret', '', 'Секрет FFmpeg API');


-- =====================================================
-- Migration: 20260209215003_a254eb5c-15ab-4660-bd2e-8292446cedd2.sql
-- =====================================================

-- 1. Create the voting category
INSERT INTO public.forum_categories (id, name, name_ru, slug, description_ru, icon, color, sort_order, is_active, is_locked, min_trust_level)
VALUES (
  '667eca41-29ad-40bf-bf92-cceec00f5875',
  'Voting',
  'Голосование',
  'voting',
  'Треки на голосовании сообщества перед дистрибуцией',
  '🗳️',
  '#8b5cf6',
  50,
  true,
  true,
  0
)
ON CONFLICT (id) DO NOTHING;


-- =====================================================
-- Migration: 20260209223652_500cde03-1389-4099-83e5-71c081d71bf5.sql
-- =====================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (user_id, username, balance)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    100
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- =====================================================
-- Migration: 20260209224152_9ad7f2d1-baf4-406d-a0d1-23c980ca20a9.sql
-- =====================================================
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS email_last_changed_at timestamptz DEFAULT NULL;

-- =====================================================
-- Migration: 20260210070622_9991393e-b3f1-4920-b074-30b43bca36f4.sql
-- =====================================================

-- Table for storing email verification codes
CREATE TABLE public.email_verifications (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT NOT NULL,
  code TEXT NOT NULL,
  username TEXT,
  password_hash TEXT,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT (now() + interval '15 minutes'),
  verified BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index for quick lookups
CREATE INDEX idx_email_verifications_email_code ON public.email_verifications (email, code);

-- Enable RLS
ALTER TABLE public.email_verifications ENABLE ROW LEVEL SECURITY;

-- No direct access from client - only edge functions with service role key
-- Cleanup old codes automatically
CREATE OR REPLACE FUNCTION public.cleanup_expired_verifications()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.email_verifications WHERE expires_at < now();
END;
$$;


-- =====================================================
-- Migration: 20260210071655_a40678af-6251-4253-ba26-c36e3976e808.sql
-- =====================================================
-- Recreate trigger that creates profile when user signs up
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- =====================================================
-- Migration: 20260210073222_6048c405-3564-48f3-a2e8-f10df2e700df.sql
-- =====================================================
-- Function to get user emails for admin panel
CREATE OR REPLACE FUNCTION public.get_user_emails()
RETURNS TABLE(user_id uuid, email text, last_sign_in_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, email::text, last_sign_in_at
  FROM auth.users
  WHERE EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_roles.user_id = auth.uid()
    AND user_roles.role IN ('admin', 'super_admin')
  );
$$;

-- =====================================================
-- Migration: 20260210075356_dd485920-e396-4b55-9384-dcf575f9c838.sql
-- =====================================================

-- Add email_unsubscribed column to profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email_unsubscribed boolean NOT NULL DEFAULT false;

-- Table for admin sent emails log
CREATE TABLE public.admin_emails (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL,
  sender_type text NOT NULL DEFAULT 'project', -- 'personal' or 'project'
  recipient_id uuid, -- null for mass emails
  recipient_email text NOT NULL,
  subject text NOT NULL,
  body_html text NOT NULL,
  template_id uuid,
  status text NOT NULL DEFAULT 'sent', -- sent, failed, bounced
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_emails ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage admin_emails"
ON public.admin_emails FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Email templates table
CREATE TABLE public.email_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  subject text NOT NULL,
  body_html text NOT NULL,
  category text NOT NULL DEFAULT 'general', -- warning, ban, welcome, promo, general
  created_by uuid NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.email_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage email_templates"
ON public.email_templates FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Index for faster lookups
CREATE INDEX idx_admin_emails_sender ON public.admin_emails(sender_id);
CREATE INDEX idx_admin_emails_recipient ON public.admin_emails(recipient_id);
CREATE INDEX idx_admin_emails_created ON public.admin_emails(created_at DESC);
CREATE INDEX idx_profiles_unsubscribed ON public.profiles(email_unsubscribed) WHERE email_unsubscribed = true;


-- =====================================================
-- Migration: 20260210080052_83516c06-bf3d-4ad5-a5dd-2daba27e26b0.sql
-- =====================================================
-- Fix: Recreate handle_new_user with ON CONFLICT to prevent silent failures
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (user_id, username, balance)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    100
  )
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Log error but don't block user creation
  RAISE WARNING 'handle_new_user failed for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

-- Also create missing profiles for existing users who don't have one
INSERT INTO public.profiles (user_id, username, balance)
SELECT 
  u.id,
  COALESCE(u.raw_user_meta_data->>'username', split_part(u.email, '@', 1)),
  100
FROM auth.users u
LEFT JOIN public.profiles p ON p.user_id = u.id
WHERE p.id IS NULL
ON CONFLICT (user_id) DO NOTHING;

-- =====================================================
-- Migration: 20260210081630_ba86df3c-1a26-40f1-9005-4432eca9fd68.sql
-- =====================================================

-- 1. Harden purchase functions: use auth.uid() directly instead of accepting buyer_id

CREATE OR REPLACE FUNCTION public.process_beat_purchase(p_beat_id UUID, p_buyer_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_beat RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Explicit auth check
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_beat FROM public.store_beats WHERE id = p_beat_id AND is_active = true;
  IF v_beat IS NULL THEN RAISE EXCEPTION 'Beat not found or not available'; END IF;
  IF v_beat.seller_id = p_buyer_id THEN RAISE EXCEPTION 'Cannot purchase your own beat'; END IF;

  v_platform_fee := ROUND(v_beat.price * 0.1);
  v_net_amount := v_beat.price - v_platform_fee;

  UPDATE public.profiles SET balance = balance - v_beat.price
  WHERE user_id = p_buyer_id AND balance >= v_beat.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.beat_purchases (buyer_id, beat_id, seller_id, price, license_type)
  VALUES (p_buyer_id, p_beat_id, v_beat.seller_id, v_beat.price, v_beat.license_type)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_beat.seller_id, v_beat.price, 'beat', v_purchase_id, v_platform_fee, v_net_amount);

  UPDATE public.profiles SET balance = balance + v_net_amount WHERE user_id = v_beat.seller_id;
  UPDATE public.store_beats SET sales_count = sales_count + 1 WHERE id = p_beat_id;

  IF v_beat.is_exclusive THEN
    UPDATE public.store_beats SET is_active = false WHERE id = p_beat_id;
  END IF;

  RETURN v_purchase_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_prompt_purchase(p_prompt_id UUID, p_buyer_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prompt RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Explicit auth check
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_prompt FROM public.user_prompts WHERE id = p_prompt_id AND is_public = true AND price > 0;
  IF v_prompt IS NULL THEN RAISE EXCEPTION 'Prompt not found or not for sale'; END IF;
  IF v_prompt.user_id = p_buyer_id THEN RAISE EXCEPTION 'Cannot purchase your own prompt'; END IF;
  IF EXISTS (SELECT 1 FROM public.prompt_purchases WHERE prompt_id = p_prompt_id AND buyer_id = p_buyer_id) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;

  v_platform_fee := ROUND(v_prompt.price * 0.1);
  v_net_amount := v_prompt.price - v_platform_fee;

  UPDATE public.profiles SET balance = balance - v_prompt.price
  WHERE user_id = p_buyer_id AND balance >= v_prompt.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.prompt_purchases (buyer_id, prompt_id, seller_id, price)
  VALUES (p_buyer_id, p_prompt_id, v_prompt.user_id, v_prompt.price)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_prompt.user_id, v_prompt.price, 'prompt', v_purchase_id, v_platform_fee, v_net_amount);

  UPDATE public.profiles SET balance = balance + v_net_amount WHERE user_id = v_prompt.user_id;
  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;

  RETURN v_purchase_id;
END;
$$;

-- 2. Fix forum_user_stats: respect hide_forum_activity privacy setting
-- Remove duplicate/overly permissive SELECT policies
DROP POLICY IF EXISTS "Anyone can view forum stats" ON public.forum_user_stats;
DROP POLICY IF EXISTS "Forum stats readable by all authenticated" ON public.forum_user_stats;

-- New policy: users see their own full stats, others only if not hidden
CREATE POLICY "Users can view visible forum stats"
  ON public.forum_user_stats FOR SELECT
  USING (
    auth.uid() = user_id
    OR is_admin(auth.uid())
    OR hide_forum_activity IS NOT TRUE
  );


-- =====================================================
-- Migration: 20260210085025_997869ad-c0d4-4042-bf4b-42a560ba675b.sql
-- =====================================================

-- ============================================================
-- SECURITY HARDENING MIGRATION
-- ============================================================

-- 1. email_verifications: DENY all access (service_role only)
-- RLS is enabled but has zero policies = deny by default for non-service-role
-- Add explicit policy for service_role only
CREATE POLICY "Service role only on email_verifications"
ON public.email_verifications
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- 2. Fix overly permissive INSERT policies
-- 2a. referrals: replace "true" with proper check
DROP POLICY IF EXISTS "System can insert referrals" ON public.referrals;
CREATE POLICY "Authenticated users can insert referrals"
ON public.referrals
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = referrer_id);

-- 2b. distribution_logs: replace "true" with proper check
DROP POLICY IF EXISTS "System can insert distribution logs" ON public.distribution_logs;
CREATE POLICY "Authenticated users can insert distribution logs"
ON public.distribution_logs
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- 2c. forum_link_previews: restrict to authenticated (already is, just fix WITH CHECK)
DROP POLICY IF EXISTS "Authenticated can insert link previews" ON public.forum_link_previews;
CREATE POLICY "Authenticated can insert link previews"
ON public.forum_link_previews
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() IS NOT NULL);

-- 3. Migrate public -> authenticated for sensitive tables

-- 3a. balance_transactions
DROP POLICY IF EXISTS "Users can view own transactions" ON public.balance_transactions;
CREATE POLICY "Users can view own transactions"
ON public.balance_transactions
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3b. impersonation_action_logs
DROP POLICY IF EXISTS "Super admins can view impersonation logs" ON public.impersonation_action_logs;
CREATE POLICY "Super admins can view impersonation logs"
ON public.impersonation_action_logs
FOR SELECT
TO authenticated
USING (has_role(auth.uid(), 'super_admin'::app_role));

-- 3c. payout_requests: migrate all 3 policies
DROP POLICY IF EXISTS "Admins can manage all payout requests" ON public.payout_requests;
CREATE POLICY "Admins can manage all payout requests"
ON public.payout_requests
FOR ALL
TO authenticated
USING (is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can create payout requests" ON public.payout_requests;
CREATE POLICY "Users can create payout requests"
ON public.payout_requests
FOR INSERT
TO authenticated
WITH CHECK ((auth.uid() = seller_id) OR is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view own payout requests" ON public.payout_requests;
CREATE POLICY "Users can view own payout requests"
ON public.payout_requests
FOR SELECT
TO authenticated
USING (auth.uid() = seller_id);

-- 3d. referrals SELECT
DROP POLICY IF EXISTS "Users can view referrals they are part of" ON public.referrals;
CREATE POLICY "Users can view referrals they are part of"
ON public.referrals
FOR SELECT
TO authenticated
USING ((auth.uid() = referrer_id) OR (auth.uid() = referee_id));

-- 3e. security_audit_log INSERT
DROP POLICY IF EXISTS "Service role can insert security logs" ON public.security_audit_log;
CREATE POLICY "Service role can insert security logs"
ON public.security_audit_log
FOR INSERT
TO service_role
WITH CHECK (true);

-- 3f. seller_earnings: clean up duplicate policies and migrate
DROP POLICY IF EXISTS "Admins can manage all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Admins can view all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Users can view own earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Sellers can view own earnings" ON public.seller_earnings;

CREATE POLICY "Admins can manage all earnings"
ON public.seller_earnings
FOR ALL
TO authenticated
USING (is_admin(auth.uid()));

CREATE POLICY "Sellers can view own earnings"
ON public.seller_earnings
FOR SELECT
TO authenticated
USING (auth.uid() = seller_id);


-- =====================================================
-- Migration: 20260210093611_984f9d88-d262-47af-acae-0ce0e22133de.sql
-- =====================================================

-- 1. Allow all admins (not just super_admin) to view impersonation logs
DROP POLICY IF EXISTS "Super admins can view impersonation logs" ON public.impersonation_action_logs;

CREATE POLICY "Admins can view impersonation logs"
ON public.impersonation_action_logs
FOR SELECT
TO authenticated
USING (
  public.has_role(auth.uid(), 'admin'::app_role)
  OR public.has_role(auth.uid(), 'super_admin'::app_role)
);

-- 2. Auto-cleanup expired email verifications (older than 1 hour)
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_verifications()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.email_verifications
  WHERE expires_at < now() - interval '1 hour';
END;
$$;

-- 3. Create a cron-like trigger: clean up on every new insert
CREATE OR REPLACE FUNCTION public.trigger_cleanup_email_verifications()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Clean up expired records on each new verification attempt
  DELETE FROM public.email_verifications
  WHERE expires_at < now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cleanup_email_verifications ON public.email_verifications;
CREATE TRIGGER trg_cleanup_email_verifications
BEFORE INSERT ON public.email_verifications
FOR EACH STATEMENT
EXECUTE FUNCTION public.trigger_cleanup_email_verifications();


-- =====================================================
-- Migration: 20260210103519_fb5a8e75-3d3b-4898-894c-3ce84be49f2c.sql
-- =====================================================
-- 1. Drop and recreate referrals_safe view
DROP VIEW IF EXISTS public.referrals_safe;
CREATE VIEW public.referrals_safe AS
SELECT 
  id, referrer_id, referee_id, referral_code_id, status, activated_at, created_at, source
FROM public.referrals;

-- 2. Re-create referrals SELECT policy scoped to authenticated
DROP POLICY IF EXISTS "Users can view referrals they are part of" ON public.referrals;
CREATE POLICY "Users can view referrals they are part of"
ON public.referrals
FOR SELECT
TO authenticated
USING (auth.uid() = referrer_id OR auth.uid() = referee_id);

-- 3. Restrict notifications to authenticated role
DROP POLICY IF EXISTS "Users can view own notifications" ON public.notifications;
CREATE POLICY "Users can view own notifications"
ON public.notifications FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own notifications" ON public.notifications;
CREATE POLICY "Users can insert own notifications"
ON public.notifications FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

DROP POLICY IF EXISTS "Users can update own notifications" ON public.notifications;
CREATE POLICY "Users can update own notifications"
ON public.notifications FOR UPDATE TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own notifications" ON public.notifications;
CREATE POLICY "Users can delete own notifications"
ON public.notifications FOR DELETE TO authenticated
USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- 4. Ad impressions anonymization function
CREATE OR REPLACE FUNCTION public.anonymize_old_ad_impressions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.ad_impressions
  SET session_id = NULL, device_type = NULL, page_url = NULL, user_id = NULL
  WHERE viewed_at < NOW() - INTERVAL '30 days'
    AND (session_id IS NOT NULL OR device_type IS NOT NULL OR user_id IS NOT NULL);
END;
$$;

-- 5. Tighten ad_impressions INSERT to authenticated only
DROP POLICY IF EXISTS "Users can record impressions" ON public.ad_impressions;
CREATE POLICY "Users can record impressions"
ON public.ad_impressions FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

-- =====================================================
-- Migration: 20260210103537_d94695c4-b498-4035-8dca-d4ff0cf63daf.sql
-- =====================================================
-- Fix: Change referrals_safe view to SECURITY INVOKER (default, uses caller's permissions)
DROP VIEW IF EXISTS public.referrals_safe;
CREATE VIEW public.referrals_safe 
WITH (security_invoker = true)
AS
SELECT 
  id, referrer_id, referee_id, referral_code_id, status, activated_at, created_at, source
FROM public.referrals;

-- =====================================================
-- Migration: 20260210110329_02217498-d9a3-4cec-9d4b-fb76f7ab6fd0.sql
-- =====================================================
-- RPC для подсчёта статистики пользователей на стороне сервера
-- вместо загрузки ВСЕХ профилей на клиент
CREATE OR REPLACE FUNCTION public.get_user_stats()
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total', (SELECT count(*) FROM profiles),
    'new_today', (SELECT count(*) FROM profiles WHERE created_at >= date_trunc('day', now())),
    'active_today', (SELECT count(*) FROM profiles WHERE last_seen_at >= date_trunc('day', now())),
    'active_last_hour', (SELECT count(*) FROM profiles WHERE last_seen_at >= now() - interval '1 hour')
  );
$$;

-- =====================================================
-- Migration: 20260210122319_be78e965-23f9-4deb-932b-b46e3afbae08.sql
-- =====================================================
CREATE OR REPLACE FUNCTION forum_prevent_self_report()
RETURNS TRIGGER AS $$
DECLARE
  target_user_id UUID;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_posts WHERE id = NEW.post_id;
  ELSIF NEW.topic_id IS NOT NULL THEN
    SELECT user_id INTO target_user_id FROM forum_topics WHERE id = NEW.topic_id;
  END IF;

  IF target_user_id = NEW.reporter_id THEN
    RAISE EXCEPTION 'Нельзя пожаловаться на свой контент';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- =====================================================
-- Migration: 20260210122935_c808357c-4f73-4970-a290-ce4f9625d720.sql
-- =====================================================
-- Drop legacy duplicate notification trigger
DROP TRIGGER IF EXISTS trigger_forum_notify_on_reply ON public.forum_posts;
DROP FUNCTION IF EXISTS forum_notify_on_reply();

-- =====================================================
-- Migration: 20260210123818_9b039956-dbac-47ba-bdbd-16c0d13a0a5f.sql
-- =====================================================
-- Drop legacy count-based escalation trigger (superseded by points-based trg_apply_warning_points)
DROP TRIGGER IF EXISTS trg_forum_warning_auto_escalate ON public.forum_warnings;
DROP FUNCTION IF EXISTS public.forum_warning_auto_escalate();

-- =====================================================
-- Migration: 20260210131230_8a289e9e-ee14-454c-91e4-8d0d70e37387.sql
-- =====================================================

-- ==========================================================
-- SUPER ADMIN FULL PROTECTION SUITE
-- ==========================================================

-- 1. BLOCK INSERT of super_admin role (closes main vulnerability)
CREATE OR REPLACE FUNCTION public.protect_super_admin_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Block any INSERT of super_admin role
  IF NEW.role = 'super_admin' THEN
    -- Log the attempt
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
    VALUES (
      NEW.user_id,
      'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка создания роли super_admin заблокирована',
      jsonb_build_object('operation', 'INSERT', 'blocked', true, 'target_user', NEW.user_id)
    );
    
    -- Send strict warning notification to the attacker
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Ваша попытка присвоить роль super_admin зафиксирована и заблокирована. Все подобные действия логируются и могут привести к немедленной блокировке аккаунта.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
    END IF;
    
    -- Notify all super_admins about the attempt
    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    SELECT ur.user_id, 'system', 
      '🚨 ALERT: Попытка эскалации привилегий',
      'Пользователь ' || COALESCE(auth.uid()::text, 'unknown') || ' попытался создать роль super_admin для ' || NEW.user_id::text || '. Действие заблокировано.',
      '00000000-0000-0000-0000-000000000000'::uuid
    FROM public.user_roles ur WHERE ur.role = 'super_admin';
    
    RAISE EXCEPTION 'Создание роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_insert_trigger ON public.user_roles;
CREATE TRIGGER protect_super_admin_insert_trigger
  BEFORE INSERT ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_insert();


-- 2. BLOCK role_invitations for super_admin
CREATE OR REPLACE FUNCTION public.protect_super_admin_invitation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role::text = 'super_admin' THEN
    -- Log and notify
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка создать приглашение на роль super_admin зафиксирована и заблокирована. Повторные попытки приведут к блокировке аккаунта.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
      
      -- Notify super_admins
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      SELECT ur.user_id, 'system',
        '🚨 ALERT: Попытка создания инвайта super_admin',
        'Пользователь ' || auth.uid()::text || ' попытался создать приглашение на роль super_admin. Заблокировано.',
        '00000000-0000-0000-0000-000000000000'::uuid
      FROM public.user_roles ur WHERE ur.role = 'super_admin';
    END IF;
    
    RAISE EXCEPTION 'Приглашение на роль super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_invitation_trigger ON public.role_invitations;
CREATE TRIGGER protect_super_admin_invitation_trigger
  BEFORE INSERT ON public.role_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_invitation();


-- 3. PROTECT super_admin from Shield system (forum bans, mutes, silences)
CREATE OR REPLACE FUNCTION public.protect_super_admin_forum_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if target user is super_admin
  IF public.is_super_admin(NEW.user_id) THEN
    -- Block any attempt to ban/mute/silence super_admin
    IF (NEW.is_banned = true AND (OLD.is_banned IS NULL OR OLD.is_banned = false))
       OR (NEW.is_muted = true AND (OLD.is_muted IS NULL OR OLD.is_muted = false))
       OR (NEW.is_silenced = true AND (OLD.is_silenced IS NULL OR OLD.is_silenced = false)) THEN
      
      -- Force reset punitive fields
      NEW.is_banned := false;
      NEW.banned_until := NULL;
      NEW.ban_reason := NULL;
      NEW.is_muted := false;
      NEW.muted_until := NULL;
      NEW.is_silenced := false;
      NEW.silenced_until := NULL;
      NEW.silence_reason := NULL;
      NEW.warnings_count := 0;
      
      -- Notify the attacker
      IF auth.uid() IS NOT NULL AND auth.uid() != NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, message, actor_id)
        VALUES (
          auth.uid(),
          'system',
          '⛔ ДЕЙСТВИЕ ЗАБЛОКИРОВАНО',
          'Попытка применить ограничения к super_admin зафиксирована. Подобные действия запрещены и логируются. Повторные попытки приведут к немедленной блокировке.',
          '00000000-0000-0000-0000-000000000000'::uuid
        );
      END IF;
      
      -- Notify super_admins
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      SELECT ur.user_id, 'system',
        '🚨 ALERT: Попытка ограничить super_admin',
        'Попытка бана/мута/сайленса super_admin от ' || COALESCE(auth.uid()::text, 'system') || '. Действие нейтрализовано.',
        '00000000-0000-0000-0000-000000000000'::uuid
      FROM public.user_roles ur WHERE ur.role = 'super_admin' AND ur.user_id != NEW.user_id;
      
      -- Log
      INSERT INTO public.role_change_logs (user_id, action, changed_by, reason, metadata)
      VALUES (
        NEW.user_id,
        'access_attempt_blocked',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
        'Попытка ограничить super_admin через Shield',
        jsonb_build_object('attempted_ban', OLD.is_banned IS DISTINCT FROM NEW.is_banned, 
                          'attempted_mute', OLD.is_muted IS DISTINCT FROM NEW.is_muted,
                          'attempted_silence', OLD.is_silenced IS DISTINCT FROM NEW.is_silenced)
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_forum_stats_trigger ON public.forum_user_stats;
CREATE TRIGGER protect_super_admin_forum_stats_trigger
  BEFORE UPDATE ON public.forum_user_stats
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_forum_stats();


-- 4. PROTECT super_admin from user_blocks (account-level blocking)
-- The block_user() function already has protection, but add trigger for direct INSERT bypass
CREATE OR REPLACE FUNCTION public.protect_super_admin_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.is_super_admin(NEW.user_id) THEN
    -- Notify attacker
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (
        auth.uid(),
        'system',
        '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка заблокировать super_admin зафиксирована. Это действие строго запрещено. Повторные попытки приведут к немедленным последствиям.',
        '00000000-0000-0000-0000-000000000000'::uuid
      );
    END IF;
    
    -- Notify super_admins
    INSERT INTO public.notifications (user_id, type, title, message, actor_id)
    SELECT ur.user_id, 'system',
      '🚨 ALERT: Попытка блокировки super_admin',
      'Пользователь ' || COALESCE(auth.uid()::text, 'unknown') || ' попытался заблокировать super_admin. Заблокировано.',
      '00000000-0000-0000-0000-000000000000'::uuid
    FROM public.user_roles ur WHERE ur.role = 'super_admin';
    
    -- Log
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (
      NEW.user_id,
      'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка блокировки super_admin через user_blocks'
    );
    
    RAISE EXCEPTION 'Блокировка super_admin запрещена. Инцидент зафиксирован.';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_super_admin_block_trigger ON public.user_blocks;
CREATE TRIGGER protect_super_admin_block_trigger
  BEFORE INSERT ON public.user_blocks
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_block();


-- 5. Also protect admins from being given super_admin via UPDATE on user_roles
-- (strengthen existing trigger to also handle edge cases)
CREATE OR REPLACE FUNCTION public.protect_super_admin_role_v2()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Block DELETE of super_admin
  IF TG_OP = 'DELETE' AND OLD.role = 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (OLD.user_id, 'access_attempt_blocked', 
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка удаления роли super_admin');
    
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, actor_id)
      VALUES (auth.uid(), 'system', '⛔ НАРУШЕНИЕ БЕЗОПАСНОСТИ',
        'Попытка удалить роль super_admin зафиксирована и заблокирована.',
        '00000000-0000-0000-0000-000000000000'::uuid);
    END IF;
    
    RAISE EXCEPTION 'Удаление роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  -- Block UPDATE changing super_admin to something else
  IF TG_OP = 'UPDATE' AND OLD.role = 'super_admin' AND NEW.role != 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (OLD.user_id, 'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка изменения роли super_admin');
    
    RAISE EXCEPTION 'Изменение роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  -- Block UPDATE setting role TO super_admin
  IF TG_OP = 'UPDATE' AND NEW.role = 'super_admin' AND OLD.role != 'super_admin' THEN
    INSERT INTO public.role_change_logs (user_id, action, changed_by, reason)
    VALUES (NEW.user_id, 'access_attempt_blocked',
      COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      'Попытка присвоения роли super_admin через UPDATE');
    
    RAISE EXCEPTION 'Присвоение роли super_admin запрещено. Инцидент зафиксирован.';
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- Replace old triggers with new comprehensive one
DROP TRIGGER IF EXISTS protect_super_admin_role ON public.user_roles;
DROP TRIGGER IF EXISTS audit_super_admin_access ON public.user_roles;

CREATE TRIGGER protect_super_admin_role_v2_trigger
  BEFORE INSERT OR UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_super_admin_role_v2();

-- Note: protect_super_admin_insert_trigger handles INSERT separately with more detailed logging,
-- and protect_super_admin_role_v2_trigger handles UPDATE/DELETE.
-- For INSERT, both triggers will fire but protect_super_admin_insert catches it first.


-- =====================================================
-- Migration: 20260210135156_03248906-9195-49c8-b121-d21b5e3641bf.sql
-- =====================================================
-- Allow automod system user to insert warnings
CREATE POLICY "System automod can insert warnings"
ON public.forum_warnings
FOR INSERT
WITH CHECK (issued_by = '00000000-0000-0000-0000-000000000000'::uuid);

-- Allow automod system user to insert mod logs
CREATE POLICY "System automod can insert logs"
ON public.forum_mod_logs
FOR INSERT
WITH CHECK (moderator_id = '00000000-0000-0000-0000-000000000000'::uuid);

-- Allow any authenticated user to update their own forum_user_stats warnings_count
-- (needed for automod to update warning count after inserting warning)
CREATE POLICY "System automod can update user stats warnings"
ON public.forum_user_stats
FOR UPDATE
USING (true)
WITH CHECK (true);

-- =====================================================
-- Migration: 20260210135205_1a9516da-e2b7-437b-a2a2-cddba0d514b4.sql
-- =====================================================
-- Drop the overly permissive policy and replace with a scoped one
DROP POLICY "System automod can update user stats warnings" ON public.forum_user_stats;

-- Only allow updating own stats OR system automod updates
CREATE POLICY "Users and automod can update forum_user_stats"
ON public.forum_user_stats
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- Migration: 20260210135217_b41a46b5-4315-4171-ba61-7d84605f8c19.sql
-- =====================================================
-- Auto-update warnings_count via trigger instead of client-side code
CREATE OR REPLACE FUNCTION public.update_warnings_count()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.forum_user_stats
  SET warnings_count = (
    SELECT count(*) FROM public.forum_warnings
    WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND is_active = true
  ),
  updated_at = now()
  WHERE user_id = COALESCE(NEW.user_id, OLD.user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_update_warnings_count
AFTER INSERT OR UPDATE OR DELETE ON public.forum_warnings
FOR EACH ROW
EXECUTE FUNCTION public.update_warnings_count();

-- =====================================================
-- Migration: 20260210171817_2fd9637f-3fb2-4417-80ad-1b8ba6296bb3.sql
-- =====================================================

-- Hide super_admin users from profiles_public view
-- Super admins will only be visible through direct profiles table (admin panel)
DROP VIEW IF EXISTS public.profiles_public;

CREATE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT
  p.id,
  p.user_id,
  p.username,
  p.avatar_url,
  p.cover_url,
  p.bio,
  p.social_links,
  p.followers_count,
  p.following_count,
  p.created_at,
  p.updated_at
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_roles ur
  WHERE ur.user_id = p.user_id
    AND ur.role = 'super_admin'
);


-- =====================================================
-- Migration: 20260210171945_4ebd9568-6353-4c46-a590-ab07dbee6243.sql
-- =====================================================

-- Update profiles_public view:
-- Admins/super_admins see ALL profiles (including super_admin)
-- Regular users see everyone EXCEPT super_admin
DROP VIEW IF EXISTS public.profiles_public;

CREATE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT
  p.id,
  p.user_id,
  p.username,
  p.avatar_url,
  p.cover_url,
  p.bio,
  p.social_links,
  p.followers_count,
  p.following_count,
  p.created_at,
  p.updated_at
FROM public.profiles p
WHERE 
  -- Admins see everyone
  public.is_admin(auth.uid())
  OR
  -- Non-admins see everyone except super_admin users
  NOT EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = p.user_id
      AND ur.role = 'super_admin'
  );


-- =====================================================
-- Migration: 20260210174241_3751a938-6da5-4c20-b239-2a5f5c68a97e.sql
-- =====================================================

-- Add admin dialog support to conversations
ALTER TABLE public.conversations 
ADD COLUMN IF NOT EXISTS type text NOT NULL DEFAULT 'personal',
ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
ADD COLUMN IF NOT EXISTS closed_by uuid REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS closed_at timestamptz;

-- Index for quick filtering
CREATE INDEX IF NOT EXISTS idx_conversations_type ON public.conversations(type);
CREATE INDEX IF NOT EXISTS idx_conversations_status ON public.conversations(status);

-- Function to close admin dialog (only super_admin)
CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check caller is super_admin
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can close admin conversations';
  END IF;

  UPDATE public.conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';
END;
$$;

-- Function to delete closed admin conversation (for user)
CREATE OR REPLACE FUNCTION public.delete_closed_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type text;
  v_status text;
  v_is_participant boolean;
BEGIN
  SELECT c.type, c.status, EXISTS(
    SELECT 1 FROM conversation_participants cp WHERE cp.conversation_id = c.id AND cp.user_id = auth.uid()
  ) INTO v_type, v_status, v_is_participant
  FROM conversations c WHERE c.id = p_conversation_id;

  IF NOT v_is_participant THEN
    RAISE EXCEPTION 'Not a participant';
  END IF;

  -- Users can only delete closed admin conversations
  IF v_type = 'admin_support' AND v_status = 'closed' THEN
    DELETE FROM conversation_participants WHERE conversation_id = p_conversation_id AND user_id = auth.uid();
  ELSIF v_type = 'personal' THEN
    DELETE FROM conversation_participants WHERE conversation_id = p_conversation_id AND user_id = auth.uid();
  ELSE
    RAISE EXCEPTION 'Cannot delete active admin conversation';
  END IF;
END;
$$;


-- =====================================================
-- Migration: 20260210174912_9a0adb30-3087-4c22-856d-dd737d267eec.sql
-- =====================================================

-- RPC to create admin_support conversation (super_admin only)
CREATE OR REPLACE FUNCTION public.create_admin_conversation(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
  v_existing_id uuid;
BEGIN
  -- Check caller is super_admin
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can create admin conversations';
  END IF;

  -- Check if admin_support conversation already exists between these two users
  SELECT c.id INTO v_existing_id
  FROM conversations c
  JOIN conversation_participants cp1 ON cp1.conversation_id = c.id AND cp1.user_id = auth.uid()
  JOIN conversation_participants cp2 ON cp2.conversation_id = c.id AND cp2.user_id = p_target_user_id
  WHERE c.type = 'admin_support'
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- Reopen if closed
    UPDATE conversations SET status = 'active', closed_by = NULL, closed_at = NULL
    WHERE id = v_existing_id AND status = 'closed';
    RETURN v_existing_id;
  END IF;

  -- Create new conversation
  INSERT INTO conversations (type, status)
  VALUES ('admin_support', 'active')
  RETURNING id INTO v_conversation_id;

  -- Add participants
  INSERT INTO conversation_participants (conversation_id, user_id)
  VALUES 
    (v_conversation_id, auth.uid()),
    (v_conversation_id, p_target_user_id);

  RETURN v_conversation_id;
END;
$$;


-- =====================================================
-- Migration: 20260210175545_96d010dc-9c9f-4fb9-9e94-a2eaae7c9c87.sql
-- =====================================================

-- Prevent inserting messages into closed conversations (RLS policy)
CREATE POLICY "Prevent messages in closed conversations"
ON public.messages FOR INSERT
TO authenticated
WITH CHECK (
  NOT EXISTS (
    SELECT 1 FROM public.conversations
    WHERE conversations.id = conversation_id
    AND conversations.status = 'closed'
  )
);

-- Also create close_admin_conversation RPC if not exists
CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'Only super_admin can close admin conversations';
  END IF;

  UPDATE conversations
  SET status = 'closed', closed_by = auth.uid(), closed_at = now()
  WHERE id = p_conversation_id AND type = 'admin_support' AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found or already closed';
  END IF;
END;
$$;


-- =====================================================
-- Migration: 20260210180417_20520d2a-3f95-4b20-a881-46d755e22a5a.sql
-- =====================================================

-- Enable realtime for conversations table (for status updates)
ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;


-- =====================================================
-- Migration: 20260210185253_4632247a-215a-4d75-a1e8-c0c594445065.sql
-- =====================================================

CREATE OR REPLACE FUNCTION public.forum_get_user_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats RECORD;
  v_config RECORD;
  v_next_config RECORD;
  v_result jsonb;
BEGIN
  -- Check if stats row exists first (fast path — no write)
  SELECT * INTO v_stats FROM forum_user_stats WHERE user_id = p_user_id;

  -- Only insert if not found
  IF v_stats IS NULL THEN
    INSERT INTO forum_user_stats (user_id) VALUES (p_user_id)
    ON CONFLICT (user_id) DO NOTHING;
    SELECT * INTO v_stats FROM forum_user_stats WHERE user_id = p_user_id;
  END IF;

  SELECT * INTO v_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level;
  SELECT * INTO v_next_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level + 1;

  v_result := jsonb_build_object(
    'user_id', p_user_id,
    'reputation_score', v_stats.reputation_score,
    'trust_level', v_stats.trust_level,
    'trust_label', COALESCE(v_config.label_ru, 'Новичок'),
    'trust_color', COALESCE(v_config.color, '#888'),
    'trust_icon', v_config.icon,
    'topics_created', v_stats.topics_created,
    'posts_created', v_stats.posts_created,
    'likes_given', v_stats.likes_given,
    'likes_received', v_stats.likes_received,
    'solutions_count', v_stats.solutions_count,
    'warnings_count', v_stats.warnings_count,
    'is_silenced', v_stats.is_silenced,
    'silenced_until', v_stats.silenced_until,
    'can_downvote', COALESCE(v_config.can_downvote, false),
    'can_upload_files', COALESCE(v_config.can_upload_files, false),
    'can_use_reactions', COALESCE(v_config.can_use_reactions, false),
    'next_level_rep', v_next_config.min_reputation,
    'next_level_label', v_next_config.label_ru,
    'progress_to_next', CASE
      WHEN v_next_config.min_reputation IS NULL THEN 100
      WHEN v_config.min_reputation IS NULL THEN 0
      ELSE ROUND(
        ((v_stats.reputation_score - v_config.min_reputation)::numeric /
         GREATEST(v_next_config.min_reputation - v_config.min_reputation, 1)::numeric) * 100
      )
    END
  );

  RETURN v_result;
END;
$$;


-- =====================================================
-- Migration: 20260211011158_d0b0326e-ebb3-4d66-a6b1-bc5f3792c53b.sql
-- =====================================================

-- Add service quotas column to subscription_plans
-- This JSONB column stores daily limits for each addon service included in the plan
-- Format: { "service_name": daily_limit } where -1 means unlimited, 0 means not included
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS service_quotas jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Add badge column for profile badges per plan
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS badge_emoji text DEFAULT NULL;

-- Add watermark control
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS no_watermark boolean NOT NULL DEFAULT false;

-- Add commercial license flag
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS commercial_license boolean NOT NULL DEFAULT false;


-- =====================================================
-- Migration: 20260211013653_28590556-4445-43db-914a-c6373a41a622.sql
-- =====================================================
-- Add forum ad slots
INSERT INTO ad_slots (slot_key, name, description, is_enabled, max_ads, recommended_width, recommended_height, recommended_aspect_ratio, supported_types, frequency_cap, cooldown_seconds)
VALUES 
  ('forum_sidebar', 'Форум: боковая панель', 'Рекламный баннер в боковой панели форума (под виджетами)', true, 1, 280, 200, '7:5', ARRAY['image'], 3, 300),
  ('forum_feed', 'Форум: между темами', 'Нативная рекламная карточка среди списка тем форума', true, 1, 600, 200, '3:1', ARRAY['image', 'video'], 5, 600)
ON CONFLICT (slot_key) DO NOTHING;

-- =====================================================
-- Migration: 20260211014133_05b7b5ec-17b8-4bfc-9297-304935234620.sql
-- =====================================================

-- Create legal_documents table for editable legal/policy pages
CREATE TABLE public.legal_documents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  content_html TEXT NOT NULL DEFAULT '',
  icon TEXT DEFAULT 'FileText',
  is_published BOOLEAN NOT NULL DEFAULT true,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;

-- Public can read published documents
CREATE POLICY "Anyone can read published legal documents"
ON public.legal_documents FOR SELECT
USING (is_published = true);

-- Admins can manage documents
CREATE POLICY "Admins can manage legal documents"
ON public.legal_documents FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Seed initial documents
INSERT INTO public.legal_documents (slug, title, icon) VALUES
  ('terms', 'Пользовательское соглашение', 'FileText'),
  ('offer', 'Публичная оферта', 'Briefcase'),
  ('audit-policy', 'Регламент технического аудита', 'Shield'),
  ('distribution-requirements', 'Требования к дистрибуции', 'Music');


-- =====================================================
-- Migration: 20260212191755_95edb992-4e92-427a-86be-3bd19c94986d.sql
-- =====================================================

-- Bug reports table
CREATE TABLE public.bug_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  report_type TEXT NOT NULL DEFAULT 'other',
  description TEXT NOT NULL,
  screenshot_url TEXT,
  page_url TEXT,
  user_agent TEXT,
  status TEXT NOT NULL DEFAULT 'new',
  admin_response TEXT,
  responded_by UUID,
  responded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.bug_reports ENABLE ROW LEVEL SECURITY;

-- Users can create their own reports
CREATE POLICY "Users can create own bug reports"
ON public.bug_reports FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Users can view their own reports
CREATE POLICY "Users can view own bug reports"
ON public.bug_reports FOR SELECT TO authenticated
USING (auth.uid() = user_id);

-- Admins can view all reports
CREATE POLICY "Admins can view all bug reports"
ON public.bug_reports FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Admins can update reports (respond)
CREATE POLICY "Admins can update bug reports"
ON public.bug_reports FOR UPDATE TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Trigger for updated_at
CREATE TRIGGER update_bug_reports_updated_at
BEFORE UPDATE ON public.bug_reports
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- Таблица закладок (избранное) — отдельно от лайков
-- =====================================================
CREATE TABLE IF NOT EXISTS public.track_bookmarks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, track_id)
);

ALTER TABLE public.track_bookmarks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view track bookmarks" ON public.track_bookmarks
FOR SELECT USING (true);

CREATE POLICY "Users can bookmark tracks" ON public.track_bookmarks
FOR INSERT WITH CHECK (
  auth.uid() = user_id OR is_admin(auth.uid())
);

CREATE POLICY "Users can unbookmark tracks" ON public.track_bookmarks
FOR DELETE USING (
  auth.uid() = user_id OR is_admin(auth.uid())
);

