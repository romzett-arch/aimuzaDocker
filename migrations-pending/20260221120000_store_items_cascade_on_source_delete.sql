-- Safety net: auto-delete store_items when the source entity (lyrics_items / user_prompts) is removed.
-- Prevents orphaned marketplace listings if the application-level delete fails.

CREATE OR REPLACE FUNCTION public.fn_delete_store_items_on_source_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF TG_TABLE_NAME = 'lyrics_items' THEN
    DELETE FROM public.store_items
     WHERE item_type = 'lyrics' AND source_id = OLD.id;
  ELSIF TG_TABLE_NAME = 'user_prompts' THEN
    DELETE FROM public.store_items
     WHERE item_type = 'prompt' AND source_id = OLD.id;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_store_items_on_lyrics_delete ON public.lyrics_items;
CREATE TRIGGER trg_delete_store_items_on_lyrics_delete
  AFTER DELETE ON public.lyrics_items
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_delete_store_items_on_source_delete();

DROP TRIGGER IF EXISTS trg_delete_store_items_on_prompt_delete ON public.user_prompts;
CREATE TRIGGER trg_delete_store_items_on_prompt_delete
  AFTER DELETE ON public.user_prompts
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_delete_store_items_on_source_delete();
