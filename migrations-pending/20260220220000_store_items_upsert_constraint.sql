-- Ensure store_items has unique constraint for upsert (seller_id, item_type, source_id)
-- Idempotent: skip if constraint already exists
DO $$
BEGIN
  ALTER TABLE public.store_items ADD CONSTRAINT store_items_seller_type_source_unique 
  UNIQUE (seller_id, item_type, source_id);
EXCEPTION WHEN duplicate_object THEN
  NULL; -- constraint already exists
END $$;

CREATE INDEX IF NOT EXISTS idx_store_items_seller_type_source 
ON public.store_items (seller_id, item_type, source_id);
