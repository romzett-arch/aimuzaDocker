-- Ensure store_items has unique constraint for upsert (seller_id, item_type, source_id)
-- Idempotent: skip if constraint already exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'store_items_seller_type_source_unique'
      AND conrelid = 'public.store_items'::regclass
  ) THEN
    ALTER TABLE public.store_items
      ADD CONSTRAINT store_items_seller_type_source_unique
      UNIQUE (seller_id, item_type, source_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_store_items_seller_type_source 
ON public.store_items (seller_id, item_type, source_id);
