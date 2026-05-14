-- Allow buyers to read purchased lyrics content (canonical schema: store_item_id)
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
