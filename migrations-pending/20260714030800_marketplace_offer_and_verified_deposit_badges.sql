DROP FUNCTION IF EXISTS public.get_marketplace_items(text);

CREATE FUNCTION public.get_marketplace_items(p_item_type text DEFAULT NULL)
RETURNS TABLE(
  id uuid, seller_id uuid, item_type text, source_id uuid, title text,
  description text, price integer, license_type text, license_terms text,
  is_exclusive boolean, is_active boolean, sales_count integer,
  views_count integer, tags text[], genre_id uuid, preview_url text,
  cover_url text, created_at timestamptz, updated_at timestamptz,
  seller_username text, seller_avatar_url text, genre_name text,
  genre_name_ru text, deposit_method text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    si.id, si.seller_id, si.item_type, si.source_id, si.title, si.description,
    si.price, si.license_type, si.license_terms, si.is_exclusive, si.is_active,
    si.sales_count, si.views_count, si.tags, si.genre_id, si.preview_url,
    si.cover_url, si.created_at, si.updated_at, p.username, p.avatar_url,
    g.name, g.name_ru,
    CASE WHEN si.item_type = 'lyrics' THEN (
      SELECT ld.method
      FROM public.lyrics_deposits ld
      WHERE ld.lyrics_id = si.source_id
        AND ld.status = 'completed'
        AND ld.evidence_version = 'aimuza-lyrics-v1'
        AND ld.proof_status IN ('platform_recorded', 'external_confirmed')
      ORDER BY CASE ld.method WHEN 'nris' THEN 0 WHEN 'irma' THEN 1 ELSE 2 END,
        ld.deposited_at DESC NULLS LAST
      LIMIT 1
    ) ELSE NULL END
  FROM public.store_items si
  LEFT JOIN public.profiles p ON p.user_id = si.seller_id
  LEFT JOIN public.genres g ON g.id = si.genre_id
  WHERE si.is_active = true
    AND (p_item_type IS NULL OR p_item_type = 'all' OR si.item_type = p_item_type)
  ORDER BY si.sales_count DESC NULLS LAST
  LIMIT 100;
$$;

REVOKE ALL ON FUNCTION public.get_marketplace_items(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_marketplace_items(text) TO anon, authenticated, service_role;
