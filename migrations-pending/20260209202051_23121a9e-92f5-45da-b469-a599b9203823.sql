
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
