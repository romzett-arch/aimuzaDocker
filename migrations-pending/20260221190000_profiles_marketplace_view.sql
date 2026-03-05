-- RPC for marketplace items with seller info (bypasses profiles RLS)
CREATE OR REPLACE FUNCTION public.get_marketplace_items(p_item_type TEXT DEFAULT NULL)
RETURNS TABLE (
  id UUID,
  seller_id UUID,
  item_type TEXT,
  source_id UUID,
  title TEXT,
  description TEXT,
  price INT,
  license_type TEXT,
  is_exclusive BOOLEAN,
  is_active BOOLEAN,
  sales_count INT,
  views_count INT,
  tags TEXT[],
  genre_id UUID,
  preview_url TEXT,
  cover_url TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  seller_username TEXT,
  seller_avatar_url TEXT,
  genre_name TEXT,
  genre_name_ru TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    si.id,
    si.seller_id,
    si.item_type,
    si.source_id,
    si.title,
    si.description,
    si.price,
    si.license_type,
    si.is_exclusive,
    si.is_active,
    si.sales_count,
    si.views_count,
    si.tags,
    si.genre_id,
    si.preview_url,
    si.cover_url,
    si.created_at,
    si.updated_at,
    p.username AS seller_username,
    p.avatar_url AS seller_avatar_url,
    g.name AS genre_name,
    g.name_ru AS genre_name_ru
  FROM store_items si
  LEFT JOIN profiles p ON p.user_id = si.seller_id
  LEFT JOIN genres g ON g.id = si.genre_id
  WHERE si.is_active = true
    AND (p_item_type IS NULL OR p_item_type = 'all' OR si.item_type = p_item_type)
  ORDER BY si.sales_count DESC NULLS LAST
  LIMIT 100;
$$;

GRANT EXECUTE ON FUNCTION public.get_marketplace_items TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_marketplace_items TO anon;
