-- Align item_purchases with process_store_item_purchase requirements
-- Handles legacy schema: item_id -> store_item_id, add missing columns

-- 0. Drop policy that may depend on item_id (will be recreated below)
DROP POLICY IF EXISTS "lyrics_items_select_purchased" ON public.lyrics_items;

-- 1. If item_id exists, add store_item_id and migrate (for legacy DBs)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'item_id'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'store_item_id'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN store_item_id UUID REFERENCES public.store_items(id) ON DELETE CASCADE;
    UPDATE public.item_purchases SET store_item_id = item_id WHERE item_id IS NOT NULL;
    DELETE FROM public.item_purchases WHERE store_item_id IS NULL;
    ALTER TABLE public.item_purchases DROP CONSTRAINT IF EXISTS item_purchases_item_id_fkey;
    ALTER TABLE public.item_purchases DROP COLUMN item_id;
    ALTER TABLE public.item_purchases ALTER COLUMN store_item_id SET NOT NULL;
  END IF;
END $$;

-- 2. Add item_type if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'item_type'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN item_type TEXT;
    UPDATE public.item_purchases ip SET item_type = si.item_type 
    FROM public.store_items si WHERE si.id = ip.store_item_id;
    ALTER TABLE public.item_purchases ALTER COLUMN item_type SET NOT NULL;
    ALTER TABLE public.item_purchases ALTER COLUMN item_type SET DEFAULT 'lyrics';
  END IF;
END $$;

-- 3. Add source_id if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'source_id'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN source_id UUID;
    UPDATE public.item_purchases ip SET source_id = si.source_id 
    FROM public.store_items si WHERE si.id = ip.store_item_id;
    ALTER TABLE public.item_purchases ALTER COLUMN source_id SET NOT NULL;
  END IF;
END $$;

-- 4. Add license_type if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'license_type'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN license_type TEXT NOT NULL DEFAULT 'standard';
  END IF;
END $$;

-- 5. Add platform_fee if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'platform_fee'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN platform_fee INTEGER DEFAULT 0;
  END IF;
END $$;

-- 6. Add net_amount if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'net_amount'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN net_amount INTEGER DEFAULT 0;
    UPDATE public.item_purchases SET net_amount = price WHERE net_amount = 0;
  END IF;
END $$;

-- 7. Add download_url if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'item_purchases' AND column_name = 'download_url'
  ) THEN
    ALTER TABLE public.item_purchases ADD COLUMN download_url TEXT;
  END IF;
END $$;

-- 8. Ensure buyer_id, seller_id, price NOT NULL
ALTER TABLE public.item_purchases ALTER COLUMN buyer_id SET NOT NULL;
ALTER TABLE public.item_purchases ALTER COLUMN seller_id SET NOT NULL;
ALTER TABLE public.item_purchases ALTER COLUMN price SET NOT NULL;

-- 9. Recreate lyrics buyer policy (uses store_item_id)
CREATE POLICY "lyrics_items_select_purchased" ON public.lyrics_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.item_purchases ip
      JOIN public.store_items si ON si.id = ip.store_item_id
      WHERE ip.buyer_id = auth.uid()
        AND si.item_type = 'lyrics'
        AND si.source_id = lyrics_items.id
    )
  );
