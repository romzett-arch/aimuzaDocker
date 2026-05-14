-- Fix overly permissive INSERT policy on balance_transactions
-- Only service_role should insert, drop the permissive policy
DROP POLICY "Service role can insert transactions" ON public.balance_transactions;

-- No client-side inserts allowed — service_role bypasses RLS anyway
-- This effectively means only server-side (edge functions) can insert