-- Defense in depth for the notification transport used by Support and QA.
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_owner_read ON public.notifications;
CREATE POLICY notifications_owner_read ON public.notifications
FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS notifications_owner_update ON public.notifications;
CREATE POLICY notifications_owner_update ON public.notifications
FOR UPDATE TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS notifications_owner_delete ON public.notifications;
CREATE POLICY notifications_owner_delete ON public.notifications
FOR DELETE TO authenticated
USING (user_id = auth.uid());

GRANT SELECT, UPDATE, DELETE ON public.notifications TO authenticated;
