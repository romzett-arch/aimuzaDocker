-- Миграция: 16 новых AI-сервисов в addon_services (B9, B1-B7, D1-D2)
-- Для БД, где seed уже применялся без этого блока.
INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES
  ('prompt_analyzer', 'AI-анализ промпта', 'Полная проверка style+lyrics по чек-листу, оценка 1-10, issues и fixes', 3, 'search', TRUE, 60),
  ('prompt_suggest_tags', 'AI-подбор тегов', 'AI подбирает теги для секции в Тег-студии', 2, 'tags', TRUE, 61),
  ('prompt_build_style', 'AI-построение стиля', 'AI строит style из текста и тегов', 3, 'sparkles', TRUE, 62),
  ('prompt_check_style', 'AI-проверка стиля', 'Анализ стиля на конфликты и полноту', 2, 'check-circle', TRUE, 63),
  ('prompt_auto_fix', 'AI-исправление промпта', 'Автоматическое исправление всех issues', 5, 'wrench', TRUE, 64),
  ('track_description', 'AI-описание трека', 'Генерация описания из названия, текста и жанра', 3, 'file-text', TRUE, 65),
  ('track_auto_tags', 'AI-теги трека', 'SEO-теги для поиска и каталога', 0, 'tags', TRUE, 66),
  ('support_categorize', 'AI-категоризация тикета', 'Автоопределение категории и приоритета', 0, 'folder', TRUE, 67),
  ('support_suggest_reply', 'AI-шаблон ответа', 'Предложение ответа на основе текста тикета', 0, 'message-square', TRUE, 68),
  ('admin_daily_digest', 'AI-дайджест', 'Ежедневная суммаризация для админки', 0, 'bar-chart', TRUE, 69),
  ('prompt_quality_check', 'Оценка промпта маркетплейса', 'Проверка качества перед публикацией', 3, 'star', TRUE, 70),
  ('distribution_check', 'Проверка дистрибуции', 'Валидация метаданных для стриминг-площадок', 0, 'check-circle', TRUE, 71),
  ('audio_interpretation', 'AI-анализ аудио', 'DeepSeek интерпретация метрик analyze-audio', 5, 'activity', TRUE, 72),
  ('mix_pro_analysis', 'Про-анализ микса', 'Профессиональный анализ через RoEx Tonn API', 10, 'sliders', TRUE, 73),
  ('audio_classify', 'AI-классификация жанра', 'Автоклассификация при загрузке/генерации', 0, 'music', TRUE, 74)
ON CONFLICT (name) DO NOTHING;
