-- One-time cleanup: delete all lyrics from DB and marketplace
-- Run manually or via migration. Order: store_items first, then lyrics_items.

DELETE FROM public.store_items WHERE item_type = 'lyrics';
DELETE FROM public.lyrics_items;
