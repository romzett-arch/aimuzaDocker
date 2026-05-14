-- Fix: Change referrals_safe view to SECURITY INVOKER (default, uses caller's permissions)
DROP VIEW IF EXISTS public.referrals_safe;
CREATE VIEW public.referrals_safe 
WITH (security_invoker = true)
AS
SELECT 
  id, referrer_id, referee_id, referral_code_id, status, activated_at, created_at, source
FROM public.referrals;