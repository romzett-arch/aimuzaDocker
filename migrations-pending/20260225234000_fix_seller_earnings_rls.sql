-- Fix seller_earnings RLS across schema variants:
-- some environments still have seller_id, others already migrated to user_id.

DROP POLICY IF EXISTS "Sellers can view own earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Admins can manage all earnings" ON public.seller_earnings;
DROP POLICY IF EXISTS "Users can view own earnings" ON public.seller_earnings;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'seller_earnings'
      AND column_name = 'user_id'
  ) THEN
    EXECUTE '
      CREATE POLICY "Sellers can view own earnings"
      ON public.seller_earnings
      FOR SELECT
      TO authenticated
      USING (auth.uid() = user_id)
    ';
  ELSE
    EXECUTE '
      CREATE POLICY "Sellers can view own earnings"
      ON public.seller_earnings
      FOR SELECT
      TO authenticated
      USING (auth.uid() = seller_id)
    ';
  END IF;
END $$;

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
