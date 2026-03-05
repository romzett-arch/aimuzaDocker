-- Remove beats from marketplace (store_items)
-- Keep store_beats/beat_purchases tables for historical data

BEGIN;

-- Drop the beat sync trigger
DROP TRIGGER IF EXISTS trg_sync_store_beat ON store_beats;
DROP FUNCTION IF EXISTS sync_store_beat_to_items();

-- Remove beat items from store_items
DELETE FROM store_items WHERE item_type = 'beat';

COMMIT;
