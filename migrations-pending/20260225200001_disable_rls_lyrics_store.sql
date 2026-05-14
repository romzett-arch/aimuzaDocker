-- Revert: disable RLS on lyrics_items and store_items
-- API uses set_config for JWT claims; auth.uid() may not work correctly in this setup.
-- With RLS enabled, inserts/selects can be blocked. Disabling restores full access.

ALTER TABLE public.lyrics_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_items DISABLE ROW LEVEL SECURITY;
