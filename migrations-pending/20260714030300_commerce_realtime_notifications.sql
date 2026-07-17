BEGIN;

-- Notifications are the user-scoped realtime transport for finance and deals.
DROP TRIGGER IF EXISTS trg_notify_notifications ON public.notifications;
CREATE TRIGGER trg_notify_notifications
AFTER INSERT OR UPDATE OR DELETE ON public.notifications
FOR EACH ROW EXECUTE FUNCTION public.notify_table_change();

-- When one administrator resolves a deal, notify the other administrators so
-- their open deal lists and pending counters update without a page reload.
CREATE OR REPLACE FUNCTION public.notify_admins_on_deal_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
  v_item_title text;
BEGIN
  IF NEW.admin_status IS NOT DISTINCT FROM OLD.admin_status
     OR NEW.admin_status NOT IN ('approved', 'rejected') THEN
    RETURN NEW;
  END IF;

  SELECT title INTO v_item_title
  FROM public.store_items
  WHERE id = NEW.store_item_id;

  FOR v_admin_id IN
    SELECT DISTINCT ur.user_id
    FROM public.user_roles ur
    WHERE ur.role IN ('admin', 'super_admin')
      AND ur.user_id IS DISTINCT FROM auth.uid()
  LOOP
    INSERT INTO public.notifications (
      user_id, type, title, message, actor_id, target_type, target_id,
      metadata
    )
    VALUES (
      v_admin_id,
      CASE WHEN NEW.admin_status = 'approved' THEN 'deal_approved' ELSE 'deal_rejected' END,
      'Статус сделки изменён',
      COALESCE(v_item_title, 'Сделка') || CASE
        WHEN NEW.admin_status = 'approved' THEN ' — одобрена'
        ELSE ' — отклонена'
      END,
      auth.uid(),
      'item_purchase',
      NEW.id,
      jsonb_build_object('admin_status', NEW.admin_status, 'admin_sync', true)
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_admins_on_deal_status_change ON public.item_purchases;
CREATE TRIGGER trg_notify_admins_on_deal_status_change
AFTER UPDATE OF admin_status ON public.item_purchases
FOR EACH ROW EXECUTE FUNCTION public.notify_admins_on_deal_status_change();

REVOKE ALL ON FUNCTION public.notify_admins_on_deal_status_change() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notify_admins_on_deal_status_change() TO service_role;

COMMIT;
