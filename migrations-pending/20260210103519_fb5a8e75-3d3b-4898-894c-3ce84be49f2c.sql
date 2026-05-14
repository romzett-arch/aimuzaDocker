-- 1. Drop and recreate referrals_safe view
DROP VIEW IF EXISTS public.referrals_safe;
CREATE VIEW public.referrals_safe AS
SELECT 
  id, referrer_id, referee_id, referral_code_id, status, activated_at, created_at, source
FROM public.referrals;

-- 2. Re-create referrals SELECT policy scoped to authenticated
DROP POLICY IF EXISTS "Users can view referrals they are part of" ON public.referrals;
CREATE POLICY "Users can view referrals they are part of"
ON public.referrals
FOR SELECT
TO authenticated
USING (auth.uid() = referrer_id OR auth.uid() = referee_id);

-- 3. Restrict notifications to authenticated role
DROP POLICY IF EXISTS "Users can view own notifications" ON public.notifications;
CREATE POLICY "Users can view own notifications"
ON public.notifications FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own notifications" ON public.notifications;
CREATE POLICY "Users can insert own notifications"
ON public.notifications FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

DROP POLICY IF EXISTS "Users can update own notifications" ON public.notifications;
CREATE POLICY "Users can update own notifications"
ON public.notifications FOR UPDATE TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own notifications" ON public.notifications;
CREATE POLICY "Users can delete own notifications"
ON public.notifications FOR DELETE TO authenticated
USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- 4. Ad impressions anonymization function
CREATE OR REPLACE FUNCTION public.anonymize_old_ad_impressions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.ad_impressions
  SET session_id = NULL, device_type = NULL, page_url = NULL, user_id = NULL
  WHERE viewed_at < NOW() - INTERVAL '30 days'
    AND (session_id IS NOT NULL OR device_type IS NOT NULL OR user_id IS NOT NULL);
END;
$$;

-- 5. Tighten ad_impressions INSERT to authenticated only
DROP POLICY IF EXISTS "Users can record impressions" ON public.ad_impressions;
CREATE POLICY "Users can record impressions"
ON public.ad_impressions FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id OR user_id IS NULL);