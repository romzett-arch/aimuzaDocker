BEGIN;

-- Make administrator notifications self-explanatory everywhere they are shown.
-- The click target remains the concrete purchase, while link provides a safe
-- fallback for clients that do not have a type-specific click handler.
CREATE OR REPLACE FUNCTION public.normalize_pending_deal_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item_title text;
  v_price integer;
BEGIN
  IF NEW.type IS DISTINCT FROM 'deal_pending_review' THEN
    RETURN NEW;
  END IF;

  IF NEW.target_type = 'item_purchase' AND NEW.target_id IS NOT NULL THEN
    SELECT si.title, ip.price
    INTO v_item_title, v_price
    FROM public.item_purchases ip
    LEFT JOIN public.store_items si ON si.id = ip.store_item_id
    WHERE ip.id = NEW.target_id;
  END IF;

  NEW.title := 'Требуется решение по сделке';
  NEW.message := CASE
    WHEN v_item_title IS NOT NULL THEN
      'Покупка текста «' || v_item_title || '» на сумму ' || COALESCE(v_price, 0) ||
      ' ₽ ожидает решения администратора. Нажмите уведомление, чтобы открыть раздел «Сделки».'
    ELSE
      'Новая сделка с текстом ожидает решения администратора. Нажмите уведомление, чтобы открыть раздел «Сделки».'
  END;
  NEW.link := '/admin/deals';
  NEW.metadata := COALESCE(NEW.metadata, '{}'::jsonb) || jsonb_build_object(
    'requires_admin_action', true,
    'admin_section', 'deals'
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_pending_deal_notification ON public.notifications;
CREATE TRIGGER trg_normalize_pending_deal_notification
BEFORE INSERT OR UPDATE OF type, target_type, target_id, title, message, link
ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.normalize_pending_deal_notification();

-- Refresh still-pending notifications, including the current E2E deal.
UPDATE public.notifications n
SET title = n.title
WHERE n.type = 'deal_pending_review'
  AND n.target_type = 'item_purchase'
  AND EXISTS (
    SELECT 1
    FROM public.item_purchases ip
    WHERE ip.id = n.target_id
      AND ip.admin_status = 'pending_review'
  );

REVOKE ALL ON FUNCTION public.normalize_pending_deal_notification() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_pending_deal_notification() TO service_role;

COMMIT;
