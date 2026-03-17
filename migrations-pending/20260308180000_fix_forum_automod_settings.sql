-- Миграция: исправление схемы forum_automod_settings + добавление forum_check_rate_limit
-- Проблема: таблица создана со старой схемой (rule_type, pattern, action, severity, settings)
--           вместо ожидаемой функциями (key, value, description).
--           Функция forum_check_rate_limit(p_user_id uuid) отсутствует в БД.

-- 1. Пересоздаём таблицу с правильной схемой
DROP TABLE IF EXISTS public.forum_automod_settings CASCADE;

CREATE TABLE public.forum_automod_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb NOT NULL DEFAULT '{}',
  description text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_automod_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can manage automod settings" ON public.forum_automod_settings;
CREATE POLICY "Admins can manage automod settings"
  ON public.forum_automod_settings
  FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

DROP POLICY IF EXISTS "Authenticated read automod settings" ON public.forum_automod_settings;
CREATE POLICY "Authenticated read automod settings"
  ON public.forum_automod_settings
  FOR SELECT
  TO authenticated
  USING (true);

-- 2. Seed: базовые настройки для forum-automod
INSERT INTO public.forum_automod_settings (key, value, description) VALUES
  ('stopwords', '{
    "enabled": true,
    "words": ["казино","ставки","1xbet","мелбет","пин-ап","купить диплом","заработок без вложений"]
  }', 'Список стоп-слов для автоскрытия'),
  ('rate_limits', '{
    "enabled": true,
    "max_posts_per_minute": 3,
    "max_topics_per_hour": 5,
    "cooldown_seconds": 15
  }', 'Лимиты частоты публикаций'),
  ('link_filter', '{
    "enabled": true,
    "max_links": 5,
    "blacklist_domains": ["1xbet.com","melbet.com","vavada.com"]
  }', 'Фильтрация ссылок'),
  ('newbie_premod', '{
    "enabled": false,
    "max_trust_level": 0
  }', 'Премодерация для новичков (trust_level = 0)'),
  ('regex_filters', '{
    "enabled": false,
    "patterns": []
  }', 'Regex-фильтры для автомодерации'),
  ('ai_moderation', '{
    "enabled": true,
    "skip_trust_level": 2,
    "confidence_threshold": 0.75,
    "min_text_length": 20,
    "spam_detection": true,
    "quality_check": false
  }', 'AI-модерация через DeepSeek (токсичность, спам). skip_trust_level — пропуск для доверенных.'),
  ('ad_policy', '{
    "enabled": true,
    "action": "auto_hide",
    "max_links_per_post": 5,
    "min_trust_level_links": 1,
    "min_trust_level_promo": 2,
    "max_promo_per_day": 3,
    "whitelist_domains": ["aimuza.ru","vk.com","youtube.com","soundcloud.com","spotify.com"],
    "blacklist_domains": ["1xbet.com","melbet.com"],
    "ai_ad_detection": false
  }', 'Политика рекламных ссылок'),
  ('report_auto_action', '{
    "enabled": true,
    "confidence_threshold": 0.85,
    "auto_warn": true
  }', 'Авто-действия по жалобам: скрытие при высокой уверенности AI'),
  ('auto_hide_threshold', '{
    "enabled": true,
    "report_count": 3
  }', 'Порог автоскрытия по количеству жалоб'),
  ('warn_expiry_days', '90', 'Срок действия предупреждений (дни)')
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = now();

-- 3. Создаём функцию forum_check_rate_limit(p_user_id uuid) для edge function forum-automod
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

  -- Проверка постов за последнюю минуту
  SELECT COUNT(*) INTO v_post_count
  FROM public.forum_posts
  WHERE user_id = p_user_id AND created_at > now() - interval '1 minute';

  IF v_post_count >= v_max_posts_per_min THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'rate_limit',
      'message', 'Слишком много сообщений. Подождите минуту.'
    );
  END IF;

  -- Проверка тем за последний час
  SELECT COUNT(*) INTO v_topic_count
  FROM public.forum_topics
  WHERE user_id = p_user_id AND created_at > now() - interval '1 hour';

  IF v_topic_count >= v_max_topics_per_hour THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'rate_limit',
      'message', 'Слишком много тем за час. Попробуйте позже.'
    );
  END IF;

  -- Проверка cooldown с последнего поста
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

GRANT EXECUTE ON FUNCTION public.forum_check_rate_limit(uuid) TO authenticated;
