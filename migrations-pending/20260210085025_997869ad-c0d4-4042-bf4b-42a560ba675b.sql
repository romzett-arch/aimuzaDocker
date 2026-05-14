
-- ============================================================
-- SECURITY HARDENING MIGRATION
-- ============================================================

-- 1. email_verifications: DENY all access (service_role only)
-- RLS is enabled but has zero policies = deny by default for non-service-role
-- Add explicit policy for service_role only
CREATE POLICY "Service role only on email_verifications"
ON public.email_verifications
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- 2. Fix overly permissive INSERT policies
-- 2a. referrals: replace "true" with proper check
DROP POLICY IF EXISTS "System can insert referrals" ON public.referrals;
CREATE POLICY "Authenticated users can insert referrals"
ON public.referrals
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = referrer_id);

-- 2b. distribution_logs: replace "true" with proper check
DROP POLICY IF EXISTS "System can insert distribution logs" ON public.distribution_logs;
CREATE POLICY "Authenticated users can insert distribution logs"
ON public.distribution_logs
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- 2c. forum_link_previews: restrict to authenticated (already is, just fix WITH CHECK)
DROP POLICY IF EXISTS "Authenticated can insert link previews" ON public.forum_link_previews;
CREATE POLICY "Authenticated can insert link previews"
ON public.forum_link_previews
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() IS NOT NULL);

-- 3. Migrate public -> authenticated for sensitive tables

-- 3a. balance_transactions
DROP POLICY IF EXISTS "Users can view own transactions" ON public.balance_transactions;
CREATE POLICY "Users can view own transactions"
ON public.balance_transactions
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3b. impersonation_action_logs
DROP POLICY IF EXISTS "Super admins can view impersonation logs" ON public.impersonation_action_logs;
CREATE POLICY "Super admins can view impersonation logs"
ON public.impersonation_action_logs
FOR SELECT
TO authenticated
USING (has_role(auth.uid(), 'super_admin'::app_role));

-- 3c. payout_requests: migrate all 3 policies
DROP POLICY IF EXISTS "Admins can manage all payout requests" ON public.payout_requests;
CREATE POLICY "Admins can manage all payout requests"
ON public.payout_requests
FOR ALL
TO authenticated
USING (is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can create payout requests" ON public.payout_requests;
CREATE POLICY "Users can create payout requests"
ON public.payout_requests
FOR INSERT
TO authenticated
WITH CHECK ((auth.uid() = seller_id) OR is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view own payout requests" ON public.payout_requests;
CREATE POLICY "Users can view own payout requests"
ON public.payout_requests
FOR SELECT
TO authenticated
USING (auth.uid() = seller_id);

-- 3d. referrals SELECT
DROP POLICY IF EXISTS "Users can view referrals they are part of" ON public.referrals;
CREATE POLICY "Users can view referrals they are part of"
ON public.referrals
FOR SELECT
TO authenticated
USING ((auth.uid() = referrer_id) OR (auth.uid() = referee_id));

-- 3e. security_audit_log INSERT
DROP POLICY IF EXISTS "Service role can insert security logs" ON public.security_audit_log;
CREATE POLICY "Service role can insert security logs"
ON public.security_audit_log
FOR INSERT
TO service_role
WITH CHECK (true);

-- 3f. seller_earnings: clean up duplicate policies and migrate
DROP POLICY IF EXISTS "Admins can manage all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Admins can view all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Users can view own earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Sellers can view own earnings" ON public.seller_earnings;

CREATE POLICY "Admins can manage all earnings"
ON public.seller_earnings
FOR ALL
TO authenticated
USING (is_admin(auth.uid()));

CREATE POLICY "Sellers can view own earnings"
ON public.seller_earnings
FOR SELECT
TO authenticated
USING (auth.uid() = seller_id);
