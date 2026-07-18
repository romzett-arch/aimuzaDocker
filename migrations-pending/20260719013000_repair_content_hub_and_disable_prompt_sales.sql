-- Repair the Content Hub and permanently disable prompt sales.
-- Prompt creation remains a paid add-on service; only resale/Marketplace listing is removed.

UPDATE public.user_prompts
SET price = 0,
    is_exclusive = false,
    license_type = 'standard',
    updated_at = now()
WHERE price IS NULL
   OR COALESCE(price, 0) <> 0
   OR COALESCE(is_exclusive, false)
   OR COALESCE(license_type, 'standard') <> 'standard';

UPDATE public.store_items
SET is_active = false,
    updated_at = now()
WHERE item_type = 'prompt'
  AND is_active IS DISTINCT FROM false;

ALTER TABLE public.user_prompts
  ALTER COLUMN price SET DEFAULT 0,
  ALTER COLUMN price SET NOT NULL;

ALTER TABLE public.user_prompts
  DROP CONSTRAINT IF EXISTS user_prompts_sales_disabled_check;

ALTER TABLE public.user_prompts
  ADD CONSTRAINT user_prompts_sales_disabled_check
  CHECK (
    price = 0
    AND COALESCE(is_exclusive, false) = false
    AND COALESCE(license_type, 'standard') = 'standard'
  );

CREATE OR REPLACE FUNCTION public.sync_prompt_to_store_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.store_items
    WHERE source_id = OLD.id
      AND item_type = 'prompt'
      AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  UPDATE public.store_items
  SET is_active = false,
      updated_at = now()
  WHERE source_id = NEW.id
    AND item_type = 'prompt'
    AND seller_id = NEW.user_id
    AND is_active IS DISTINCT FROM false;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.block_active_prompt_store_items()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.item_type = 'prompt' AND COALESCE(NEW.is_active, true) THEN
    RAISE EXCEPTION 'prompt_sales_disabled';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS block_active_prompt_store_items_trigger ON public.store_items;
CREATE TRIGGER block_active_prompt_store_items_trigger
BEFORE INSERT OR UPDATE OF item_type, is_active
ON public.store_items
FOR EACH ROW
EXECUTE FUNCTION public.block_active_prompt_store_items();

CREATE INDEX IF NOT EXISTS idx_user_prompts_user_created_at
  ON public.user_prompts(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_prompts_user_track
  ON public.user_prompts(user_id, track_id)
  WHERE track_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_lyrics_items_user_created_at
  ON public.lyrics_items(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_lyrics_items_is_for_sale
  ON public.lyrics_items(is_for_sale)
  WHERE is_for_sale = true;

CREATE INDEX IF NOT EXISTS idx_lyrics_items_genre_id
  ON public.lyrics_items(genre_id);

CREATE INDEX IF NOT EXISTS idx_lyrics_items_user_track
  ON public.lyrics_items(user_id, track_id)
  WHERE track_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_store_items_seller_id
  ON public.store_items(seller_id);

CREATE INDEX IF NOT EXISTS idx_store_items_item_type
  ON public.store_items(item_type);

CREATE INDEX IF NOT EXISTS idx_store_items_is_active
  ON public.store_items(is_active)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_store_items_genre_id
  ON public.store_items(genre_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.lyrics_items'::regclass
      AND conname = 'lyrics_items_user_id_fkey'
  ) THEN
    ALTER TABLE public.lyrics_items
      ADD CONSTRAINT lyrics_items_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.lyrics_items'::regclass
      AND conname = 'lyrics_items_track_id_fkey'
  ) THEN
    ALTER TABLE public.lyrics_items
      ADD CONSTRAINT lyrics_items_track_id_fkey
      FOREIGN KEY (track_id) REFERENCES public.tracks(id) ON DELETE SET NULL NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.lyrics_items'::regclass
      AND conname = 'lyrics_items_genre_id_fkey'
  ) THEN
    ALTER TABLE public.lyrics_items
      ADD CONSTRAINT lyrics_items_genre_id_fkey
      FOREIGN KEY (genre_id) REFERENCES public.genres(id) ON DELETE SET NULL NOT VALID;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_paid_user_prompt(
  p_title text,
  p_description text DEFAULT NULL,
  p_lyrics text DEFAULT NULL,
  p_genre_id uuid DEFAULT NULL,
  p_vocal_type_id uuid DEFAULT NULL,
  p_template_id uuid DEFAULT NULL,
  p_artist_style_id uuid DEFAULT NULL,
  p_is_public boolean DEFAULT false
)
RETURNS public.user_prompts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_price integer;
  v_prompt public.user_prompts;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION 'Prompt title is required';
  END IF;

  SELECT price_rub
  INTO v_price
  FROM public.addon_services
  WHERE name = 'create_prompt'
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_price IS NULL THEN
    RAISE EXCEPTION 'create_prompt_service_unavailable';
  END IF;

  IF v_price < 0 THEN
    RAISE EXCEPTION 'invalid_create_prompt_price';
  END IF;

  IF v_price > 0 THEN
    PERFORM public.debit_balance(v_user_id, v_price, 'Покупка промпта');
  END IF;

  INSERT INTO public.user_prompts (
    user_id,
    title,
    description,
    lyrics,
    genre_id,
    vocal_type_id,
    template_id,
    artist_style_id,
    is_public,
    price,
    is_exclusive,
    license_type
  )
  VALUES (
    v_user_id,
    btrim(p_title),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    NULLIF(COALESCE(p_lyrics, ''), ''),
    p_genre_id,
    p_vocal_type_id,
    p_template_id,
    p_artist_style_id,
    COALESCE(p_is_public, false),
    0,
    false,
    'standard'
  )
  RETURNING * INTO v_prompt;

  RETURN v_prompt;
END;
$$;

REVOKE ALL ON FUNCTION public.create_paid_user_prompt(
  text, text, text, uuid, uuid, uuid, uuid, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_paid_user_prompt(
  text, text, text, uuid, uuid, uuid, uuid, boolean
) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_user_prompt_stats(p_user_id uuid)
RETURNS TABLE(total bigint, public_count bigint, total_uses bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL OR (v_user_id <> p_user_id AND NOT public.is_admin(v_user_id)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    count(*)::bigint,
    count(*) FILTER (WHERE prompt.is_public)::bigint,
    COALESCE(sum(prompt.uses_count), 0)::bigint
  FROM public.user_prompts prompt
  WHERE prompt.user_id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.get_user_prompt_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_prompt_stats(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_prompt_purchase(p_prompt_id uuid, p_buyer_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'prompt_sales_disabled';
END;
$$;

REVOKE ALL ON FUNCTION public.process_prompt_purchase(uuid, uuid)
FROM PUBLIC, anon, authenticated;
