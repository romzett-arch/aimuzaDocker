-- Триггер: запрет дистрибуции для загруженных треков без одобрения модерации
-- Загруженный трек (source_type = 'uploaded') не может получить distribution_status
-- отличный от NULL/none, если moderation_status != 'approved'

CREATE OR REPLACE FUNCTION public.check_distribution_requires_moderation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.source_type = 'uploaded'
     AND NEW.moderation_status IS DISTINCT FROM 'approved'
     AND NEW.distribution_status IS NOT NULL
     AND NEW.distribution_status NOT IN ('none', '')
  THEN
    RAISE EXCEPTION 'Загруженные треки требуют одобрения модерации перед отправкой на дистрибуцию (moderation_status должен быть approved)';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_distribution_moderation ON public.tracks;
CREATE TRIGGER trg_check_distribution_moderation
  BEFORE INSERT OR UPDATE ON public.tracks
  FOR EACH ROW EXECUTE FUNCTION public.check_distribution_requires_moderation();
