-- Kept in sync with supabase/migrations/20261005130000_song_idea_editorial_gate.sql.
-- The deployment migration is intentionally identical.

ALTER TABLE public.song_ideas
  ADD COLUMN IF NOT EXISTS primary_genre TEXT,
  ADD COLUMN IF NOT EXISTS primary_mood TEXT,
  ADD COLUMN IF NOT EXISTS primary_theme TEXT,
  ADD COLUMN IF NOT EXISTS story_shelf TEXT,
  ADD COLUMN IF NOT EXISTS conflict_key TEXT,
  ADD COLUMN IF NOT EXISTS image_key TEXT,
  ADD COLUMN IF NOT EXISTS turn_key TEXT,
  ADD COLUMN IF NOT EXISTS hook_key TEXT,
  ADD COLUMN IF NOT EXISTS editorial_status TEXT NOT NULL DEFAULT 'draft'
    CHECK (editorial_status IN ('draft', 'accepted', 'archived', 'legacy_unverified'));

UPDATE public.song_ideas SET editorial_status = 'accepted'
WHERE is_published
  AND EXISTS (SELECT 1 FROM public.song_idea_sources s WHERE s.idea_id = song_ideas.id AND s.editorial_status = 'accepted');

UPDATE public.song_ideas
SET editorial_status = 'legacy_unverified'
WHERE is_published
  AND NOT EXISTS (SELECT 1 FROM public.song_idea_sources s WHERE s.idea_id = song_ideas.id AND s.editorial_status = 'accepted');

CREATE INDEX IF NOT EXISTS idx_song_ideas_editorial_fingerprint ON public.song_ideas (story_shelf, conflict_key, image_key, turn_key) WHERE editorial_status = 'accepted';

CREATE OR REPLACE FUNCTION public.enforce_published_song_idea_completeness()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.is_published AND (trim(NEW.title) = '' OR trim(NEW.full_story) = '' OR trim(NEW.hero_pov) = '' OR trim(NEW.central_conflict) = '' OR trim(NEW.emotional_arc) = '' OR trim(NEW.ending_direction) = '' OR trim(NEW.hook_direction) = '' OR trim(NEW.energy) = '' OR trim(NEW.generator_brief) = '' OR COALESCE(cardinality(NEW.genres), 0) = 0 OR COALESCE(cardinality(NEW.moods), 0) = 0 OR COALESCE(cardinality(NEW.themes), 0) = 0 OR EXISTS (SELECT 1 FROM unnest(NEW.genres) AS value WHERE trim(value) = '') OR EXISTS (SELECT 1 FROM unnest(NEW.moods) AS value WHERE trim(value) = '') OR EXISTS (SELECT 1 FROM unnest(NEW.themes) AS value WHERE trim(value) = '')) THEN RAISE EXCEPTION 'Нельзя опубликовать неполную карточку идеи'; END IF;
  IF NEW.is_published AND (TG_OP = 'INSERT' OR NOT OLD.is_published) THEN
    IF NEW.editorial_status <> 'accepted' OR NULLIF(trim(NEW.primary_genre), '') IS NULL OR NULLIF(trim(NEW.primary_mood), '') IS NULL OR NULLIF(trim(NEW.primary_theme), '') IS NULL OR NULLIF(trim(NEW.story_shelf), '') IS NULL OR NULLIF(trim(NEW.conflict_key), '') IS NULL OR NULLIF(trim(NEW.image_key), '') IS NULL OR NULLIF(trim(NEW.turn_key), '') IS NULL OR NULLIF(trim(NEW.hook_key), '') IS NULL THEN RAISE EXCEPTION 'Для публикации нужны принятый статус, основные фильтры и паспорт сюжета'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.song_idea_sources s WHERE s.idea_id = NEW.id AND s.editorial_status = 'accepted') THEN RAISE EXCEPTION 'Нельзя опубликовать идею без проверенного принятого первоисточника'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.song_idea_taxonomy_options t WHERE t.kind = 'genre' AND t.value = NEW.primary_genre AND t.is_active) OR NOT EXISTS (SELECT 1 FROM public.song_idea_taxonomy_options t WHERE t.kind = 'mood' AND t.value = NEW.primary_mood AND t.is_active) OR NOT EXISTS (SELECT 1 FROM public.song_idea_taxonomy_options t WHERE t.kind = 'theme' AND t.value = NEW.primary_theme AND t.is_active) OR NOT EXISTS (SELECT 1 FROM public.song_idea_taxonomy_options t WHERE t.kind = 'energy' AND t.value = NEW.energy AND t.is_active) THEN RAISE EXCEPTION 'Основные жанр, настроение, тема и энергия должны быть активными значениями словаря'; END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_published_song_idea_source()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.song_ideas i WHERE i.id = OLD.idea_id AND i.is_published) AND (TG_OP = 'DELETE' OR NEW.editorial_status <> 'accepted') THEN RAISE EXCEPTION 'Нельзя удалить или снять принятие источника у опубликованной идеи; сначала архивируйте карточку'; END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
DROP TRIGGER IF EXISTS trg_song_idea_source_protect_published ON public.song_idea_sources;
CREATE TRIGGER trg_song_idea_source_protect_published BEFORE UPDATE OF editorial_status OR DELETE ON public.song_idea_sources FOR EACH ROW EXECUTE FUNCTION public.protect_published_song_idea_source();

CREATE OR REPLACE VIEW public.song_idea_accepted_registry WITH (security_invoker = true) AS
SELECT i.id AS idea_id, i.title AS idea_title, i.primary_genre, i.primary_mood, i.primary_theme, i.energy, i.story_shelf, i.conflict_key, i.image_key, i.turn_key, i.hook_key, s.original_key, s.author_name, s.original_title, s.original_language, s.original_year, s.editorial_status AS source_status
FROM public.song_ideas i JOIN public.song_idea_sources s ON s.idea_id = i.id
WHERE i.editorial_status = 'accepted' AND s.editorial_status = 'accepted';
GRANT SELECT ON public.song_idea_accepted_registry TO authenticated;
