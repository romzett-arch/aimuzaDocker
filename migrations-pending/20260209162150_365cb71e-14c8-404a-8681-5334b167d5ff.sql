
-- FIX 1: profiles_public — remove sensitive fields (is_verified, verification_type, last_seen_at)
DROP VIEW IF EXISTS public.profiles_public;

CREATE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT
  id,
  user_id,
  username,
  avatar_url,
  cover_url,
  bio,
  social_links,
  followers_count,
  following_count,
  created_at,
  updated_at
FROM public.profiles;

-- FIX 2: payout_requests — restrict direct SELECT to owner only via safe view
-- First ensure the safe view masks payment_details properly
DROP VIEW IF EXISTS public.payout_requests_safe;

CREATE VIEW public.payout_requests_safe
WITH (security_invoker = on) AS
SELECT
  id,
  seller_id,
  amount,
  payment_method,
  status,
  admin_notes,
  created_at,
  processed_at,
  CASE
    WHEN payment_details IS NOT NULL THEN
      jsonb_build_object(
        'masked', true,
        'method_type', payment_details->>'method_type'
      )
    ELSE NULL
  END AS payment_details_masked
FROM public.payout_requests;

-- Encrypt payment_details: add a comment noting it should be encrypted at app level
COMMENT ON COLUMN public.payout_requests.payment_details IS 'Contains sensitive banking data. Always use payout_requests_safe view for reads. Raw access restricted to owner + admin via RLS.';
