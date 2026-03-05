-- Backfill store_items from store_beats and lyrics_items
-- + add triggers for automatic sync going forward

BEGIN;

-- 1. Backfill from store_beats
INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, sales_count, tags, created_at, updated_at)
SELECT
  sb.user_id,
  'beat',
  sb.id,
  COALESCE(NULLIF(TRIM(sb.title), ''), 'Без названия'),
  sb.description,
  sb.price,
  sb.license_type,
  false,
  sb.is_active,
  sb.sales_count,
  sb.tags,
  sb.created_at,
  sb.updated_at
FROM store_beats sb
WHERE sb.user_id IS NOT NULL
ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  price = EXCLUDED.price,
  license_type = EXCLUDED.license_type,
  is_active = EXCLUDED.is_active,
  sales_count = EXCLUDED.sales_count,
  updated_at = now();

-- 2. Backfill from lyrics_items (only those for sale)
INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, created_at, updated_at)
SELECT
  li.user_id,
  'lyrics',
  li.id,
  COALESCE(NULLIF(TRIM(li.title), ''), 'Без названия'),
  li.description,
  li.price,
  COALESCE(li.license_type, 'standard'),
  COALESCE(li.is_exclusive, false),
  true,
  li.created_at,
  li.updated_at
FROM lyrics_items li
WHERE li.is_for_sale = true AND li.user_id IS NOT NULL
ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  price = EXCLUDED.price,
  license_type = EXCLUDED.license_type,
  is_exclusive = EXCLUDED.is_exclusive,
  is_active = EXCLUDED.is_active,
  updated_at = now();

-- 3. Trigger: auto-sync store_beats → store_items
CREATE OR REPLACE FUNCTION sync_store_beat_to_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM store_items
    WHERE source_id = OLD.id AND item_type = 'beat' AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, sales_count, tags, created_at, updated_at)
  VALUES (
    NEW.user_id,
    'beat',
    NEW.id,
    COALESCE(NULLIF(TRIM(NEW.title), ''), 'Без названия'),
    NEW.description,
    NEW.price,
    NEW.license_type,
    false,
    NEW.is_active,
    NEW.sales_count,
    NEW.tags,
    NEW.created_at,
    now()
  )
  ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    price = EXCLUDED.price,
    license_type = EXCLUDED.license_type,
    is_active = EXCLUDED.is_active,
    sales_count = EXCLUDED.sales_count,
    tags = EXCLUDED.tags,
    updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_store_beat ON store_beats;
CREATE TRIGGER trg_sync_store_beat
  AFTER INSERT OR UPDATE OR DELETE ON store_beats
  FOR EACH ROW EXECUTE FUNCTION sync_store_beat_to_items();

-- 4. Trigger: auto-sync lyrics_items → store_items (on is_for_sale change)
CREATE OR REPLACE FUNCTION sync_lyrics_to_store_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM store_items
    WHERE source_id = OLD.id AND item_type = 'lyrics' AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  IF NEW.is_for_sale = true AND COALESCE(NEW.price, 0) > 0 THEN
    INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, created_at, updated_at)
    VALUES (
      NEW.user_id,
      'lyrics',
      NEW.id,
      COALESCE(NULLIF(TRIM(NEW.title), ''), 'Без названия'),
      NEW.description,
      NEW.price,
      COALESCE(NEW.license_type, 'standard'),
      COALESCE(NEW.is_exclusive, false),
      true,
      NEW.created_at,
      now()
    )
    ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
      title = EXCLUDED.title,
      description = EXCLUDED.description,
      price = EXCLUDED.price,
      license_type = EXCLUDED.license_type,
      is_exclusive = EXCLUDED.is_exclusive,
      is_active = true,
      updated_at = now();
  ELSE
    UPDATE store_items SET is_active = false, updated_at = now()
    WHERE source_id = NEW.id AND item_type = 'lyrics' AND seller_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_lyrics_to_store ON lyrics_items;
CREATE TRIGGER trg_sync_lyrics_to_store
  AFTER INSERT OR UPDATE OR DELETE ON lyrics_items
  FOR EACH ROW EXECUTE FUNCTION sync_lyrics_to_store_items();

-- 5. Trigger: auto-sync user_prompts → store_items (on is_public change)
CREATE OR REPLACE FUNCTION sync_prompt_to_store_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM store_items
    WHERE source_id = OLD.id AND item_type = 'prompt' AND seller_id = OLD.user_id;
    RETURN OLD;
  END IF;

  IF NEW.is_public = true THEN
    INSERT INTO store_items (seller_id, item_type, source_id, title, description, price, license_type, is_exclusive, is_active, created_at, updated_at)
    VALUES (
      NEW.user_id,
      'prompt',
      NEW.id,
      COALESCE(NULLIF(TRIM(NEW.title), ''), 'Без названия'),
      NEW.description,
      COALESCE(NEW.price, 0),
      COALESCE(NEW.license_type, 'standard'),
      COALESCE(NEW.is_exclusive, false),
      true,
      NEW.created_at,
      now()
    )
    ON CONFLICT (seller_id, item_type, source_id) DO UPDATE SET
      title = EXCLUDED.title,
      description = EXCLUDED.description,
      price = EXCLUDED.price,
      license_type = EXCLUDED.license_type,
      is_exclusive = EXCLUDED.is_exclusive,
      is_active = true,
      updated_at = now();
  ELSE
    UPDATE store_items SET is_active = false, updated_at = now()
    WHERE source_id = NEW.id AND item_type = 'prompt' AND seller_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_prompt_to_store ON user_prompts;
CREATE TRIGGER trg_sync_prompt_to_store
  AFTER INSERT OR UPDATE OR DELETE ON user_prompts
  FOR EACH ROW EXECUTE FUNCTION sync_prompt_to_store_items();

COMMIT;
