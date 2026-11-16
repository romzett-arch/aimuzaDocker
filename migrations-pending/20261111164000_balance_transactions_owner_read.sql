CREATE POLICY "Account owners can read balance transactions"
ON public.balance_transactions
FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()));
