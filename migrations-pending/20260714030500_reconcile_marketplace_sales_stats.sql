-- Marketplace counters must describe completed sales, not purchases that are
-- still waiting for moderation or have been rejected.

CREATE OR REPLACE FUNCTION public.refresh_marketplace_sale_counters()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store_item_id uuid := COALESCE(NEW.store_item_id, OLD.store_item_id);
BEGIN
  UPDATE public.store_items AS store_item
  SET sales_count = (
    SELECT COUNT(*)::integer
    FROM public.item_purchases AS purchase
    WHERE purchase.store_item_id = v_store_item_id
      AND COALESCE(purchase.admin_status, 'approved') = 'approved'
  )
  WHERE store_item.id = v_store_item_id;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS refresh_marketplace_sale_counters_on_status
  ON public.item_purchases;

CREATE TRIGGER refresh_marketplace_sale_counters_on_status
AFTER UPDATE OF admin_status OR DELETE
ON public.item_purchases
FOR EACH ROW
EXECUTE FUNCTION public.refresh_marketplace_sale_counters();

-- Reconcile counters accumulated before the trigger existed.
UPDATE public.store_items AS store_item
SET sales_count = (
  SELECT COUNT(*)::integer
  FROM public.item_purchases AS purchase
  WHERE purchase.store_item_id = store_item.id
    AND COALESCE(purchase.admin_status, 'approved') = 'approved'
);

COMMENT ON FUNCTION public.refresh_marketplace_sale_counters() IS
  'Keeps marketplace sales_count aligned with approved purchases only.';
