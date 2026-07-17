-- Video gallery foundation: owned storage metadata, lifecycle state and access rules.

UPDATE public.addon_services
SET is_active = false,
    price_rub = 0,
    name_ru = 'Видео релиз-пака',
    description = 'Внутренний технический сервис сборки релиз-пака',
    updated_at = now()
WHERE name = 'short_video';

ALTER TABLE public.track_addons
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS metadata jsonb;

UPDATE public.track_addons addon
SET user_id = track.user_id
FROM public.tracks track
WHERE track.id = addon.track_id AND addon.user_id IS NULL;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY track_id, addon_service_id
           ORDER BY (status = 'completed') DESC, updated_at DESC NULLS LAST, created_at DESC NULLS LAST, id
         ) AS duplicate_rank
  FROM public.track_addons
  WHERE track_id IS NOT NULL AND addon_service_id IS NOT NULL
)
DELETE FROM public.track_addons addon
USING ranked
WHERE addon.id = ranked.id AND ranked.duplicate_rank > 1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_track_addons_track_service_unique
  ON public.track_addons (track_id, addon_service_id)
  WHERE track_id IS NOT NULL AND addon_service_id IS NOT NULL;

ALTER TABLE public.track_addons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own track addons" ON public.track_addons;
DROP POLICY IF EXISTS "Users can insert own track addons" ON public.track_addons;
CREATE POLICY "Users can view own track addons"
  ON public.track_addons FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.tracks track
    WHERE track.id = track_addons.track_id AND track.user_id = auth.uid()
  ));
CREATE POLICY "Users can insert own track addons"
  ON public.track_addons FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.tracks track
    WHERE track.id = track_addons.track_id AND track.user_id = auth.uid()
  ));

ALTER TABLE public.gallery_items
  ADD COLUMN IF NOT EXISTS storage_bucket text,
  ADD COLUMN IF NOT EXISTS storage_path text,
  ADD COLUMN IF NOT EXISTS thumbnail_storage_path text,
  ADD COLUMN IF NOT EXISTS mime_type text,
  ADD COLUMN IF NOT EXISTS size_bytes bigint,
  ADD COLUMN IF NOT EXISTS duration_seconds numeric,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'ready',
  ADD COLUMN IF NOT EXISTS moderation_status text NOT NULL DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS published_at timestamptz;

UPDATE public.gallery_items
SET published_at = COALESCE(published_at, created_at)
WHERE is_public IS TRUE;

CREATE INDEX IF NOT EXISTS idx_gallery_items_owner_type_created
  ON public.gallery_items (user_id, type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_gallery_items_public_feed
  ON public.gallery_items (published_at DESC, id DESC)
  WHERE is_public IS TRUE AND status = 'ready' AND moderation_status = 'approved';

CREATE UNIQUE INDEX IF NOT EXISTS idx_gallery_items_storage_object
  ON public.gallery_items (storage_bucket, storage_path)
  WHERE storage_bucket IS NOT NULL AND storage_path IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gallery_items_status_check'
      AND conrelid = 'public.gallery_items'::regclass
  ) THEN
    ALTER TABLE public.gallery_items
      ADD CONSTRAINT gallery_items_status_check
      CHECK (status IN ('uploaded', 'processing', 'ready', 'failed', 'quarantined'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gallery_items_moderation_status_check'
      AND conrelid = 'public.gallery_items'::regclass
  ) THEN
    ALTER TABLE public.gallery_items
      ADD CONSTRAINT gallery_items_moderation_status_check
      CHECK (moderation_status IN ('pending', 'approved', 'rejected'));
  END IF;
END $$;

ALTER TABLE public.gallery_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gallery_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own gallery items" ON public.gallery_items;
DROP POLICY IF EXISTS "Users can view public gallery items" ON public.gallery_items;
DROP POLICY IF EXISTS "Users can insert own gallery items" ON public.gallery_items;
DROP POLICY IF EXISTS "Users can update own gallery items" ON public.gallery_items;
DROP POLICY IF EXISTS "Users can delete own gallery items" ON public.gallery_items;

CREATE POLICY "Users can view own gallery items"
  ON public.gallery_items FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Anyone can view approved public gallery items"
  ON public.gallery_items FOR SELECT TO anon, authenticated
  USING (is_public IS TRUE AND status = 'ready' AND moderation_status = 'approved');

CREATE POLICY "Users can insert own gallery items"
  ON public.gallery_items FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own gallery items"
  ON public.gallery_items FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can delete own gallery items"
  ON public.gallery_items FOR DELETE TO authenticated
  USING (user_id = auth.uid());
