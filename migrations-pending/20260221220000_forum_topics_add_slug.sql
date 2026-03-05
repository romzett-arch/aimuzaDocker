-- Add slug column to forum_topics if missing (fixes "column slug does not exist")
-- Some deployments may have forum_topics without slug from older schema

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'forum_topics' AND column_name = 'slug'
  ) THEN
    -- 1. Add column (nullable first for backfill)
    ALTER TABLE public.forum_topics ADD COLUMN slug TEXT;

    -- 2. Backfill existing rows with unique slugs (title-based + id suffix)
    UPDATE public.forum_topics t
    SET slug = (
      left(lower(regexp_replace(regexp_replace(COALESCE(t.title, 'topic'), '[^a-zа-яё0-9\s]', '', 'gi'), '\s+', '-', 'g')), 80)
      || '-' || left(replace(t.id::text, '-', ''), 8)
    )
    WHERE t.slug IS NULL;

    -- 3. Set NOT NULL
    ALTER TABLE public.forum_topics ALTER COLUMN slug SET NOT NULL;

    -- 4. Add unique constraint (category_id, slug) if not exists
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conname = 'forum_topics_category_id_slug_key'
    ) THEN
      ALTER TABLE public.forum_topics ADD CONSTRAINT forum_topics_category_id_slug_key UNIQUE (category_id, slug);
    END IF;
  END IF;
END;
$$;
