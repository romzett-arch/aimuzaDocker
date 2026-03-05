-- Restore missing RLS policies for lyrics_items and store_items
-- These policies were lost (possibly dropped during schema changes)

-- =============================================
-- 1. Enable RLS on both tables
-- =============================================
ALTER TABLE public.lyrics_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_items ENABLE ROW LEVEL SECURITY;

-- =============================================
-- 2. lyrics_items policies
-- =============================================

-- Owner can see own lyrics
DROP POLICY IF EXISTS "lyrics_items_select_own" ON public.lyrics_items;
CREATE POLICY "lyrics_items_select_own" ON public.lyrics_items
  FOR SELECT USING (auth.uid() = user_id);

-- Public lyrics visible to everyone
DROP POLICY IF EXISTS "lyrics_items_select_public" ON public.lyrics_items;
CREATE POLICY "lyrics_items_select_public" ON public.lyrics_items
  FOR SELECT USING (is_public = true AND is_for_sale = true AND is_active = true);

-- Buyer can read purchased lyrics (already exists, recreate idempotently)
DROP POLICY IF EXISTS "lyrics_items_select_purchased" ON public.lyrics_items;
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

-- Owner can insert own lyrics
DROP POLICY IF EXISTS "lyrics_items_insert" ON public.lyrics_items;
CREATE POLICY "lyrics_items_insert" ON public.lyrics_items
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Owner can update own lyrics
DROP POLICY IF EXISTS "lyrics_items_update" ON public.lyrics_items;
CREATE POLICY "lyrics_items_update" ON public.lyrics_items
  FOR UPDATE USING (auth.uid() = user_id);

-- Owner can delete own lyrics
DROP POLICY IF EXISTS "lyrics_items_delete" ON public.lyrics_items;
CREATE POLICY "lyrics_items_delete" ON public.lyrics_items
  FOR DELETE USING (auth.uid() = user_id);

-- Admin full access
DROP POLICY IF EXISTS "lyrics_items_admin" ON public.lyrics_items;
CREATE POLICY "lyrics_items_admin" ON public.lyrics_items
  FOR ALL USING (public.is_admin(auth.uid()));

-- =============================================
-- 3. store_items policies
-- =============================================

-- Anyone can see active items
DROP POLICY IF EXISTS "store_items_select_active" ON public.store_items;
CREATE POLICY "store_items_select_active" ON public.store_items
  FOR SELECT USING (is_active = true);

-- Owner can see own items (including inactive)
DROP POLICY IF EXISTS "store_items_select_own" ON public.store_items;
CREATE POLICY "store_items_select_own" ON public.store_items
  FOR SELECT USING (auth.uid() = seller_id);

-- Owner can insert items
DROP POLICY IF EXISTS "store_items_insert" ON public.store_items;
CREATE POLICY "store_items_insert" ON public.store_items
  FOR INSERT WITH CHECK (auth.uid() = seller_id);

-- Owner can update items
DROP POLICY IF EXISTS "store_items_update" ON public.store_items;
CREATE POLICY "store_items_update" ON public.store_items
  FOR UPDATE USING (auth.uid() = seller_id);

-- Owner can delete items
DROP POLICY IF EXISTS "store_items_delete" ON public.store_items;
CREATE POLICY "store_items_delete" ON public.store_items
  FOR DELETE USING (auth.uid() = seller_id);

-- Admin full access
DROP POLICY IF EXISTS "store_items_admin" ON public.store_items;
CREATE POLICY "store_items_admin" ON public.store_items
  FOR ALL USING (public.is_admin(auth.uid()));
