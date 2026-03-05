-- Fix: seller_earnings has column user_id (not seller_id)
-- RLS was enabled but no policies existed → SELECT blocked for everyone
-- Add proper RLS policies using user_id column

DROP POLICY IF EXISTS "Sellers can view own earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Admins can manage all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Users can view own earnings" ON public.seller_earnings;

CREATE POLICY "Sellers can view own earnings"
ON public.seller_earnings
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all earnings"
ON public.seller_earnings
FOR ALL
TO authenticated
USING (public.is_admin(auth.uid()));

CREATE POLICY "Service can insert earnings"
ON public.seller_earnings
FOR INSERT
TO authenticated
WITH CHECK (true);
