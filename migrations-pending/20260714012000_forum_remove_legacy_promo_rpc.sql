-- Remove the obsolete public promo moderation entry point. The current
-- four-argument RPC performs role checks, locks the slot and refunds atomically.

DROP FUNCTION IF EXISTS public.forum_moderate_promo(uuid, text);

REVOKE ALL ON FUNCTION public.forum_moderate_promo(uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_moderate_promo(uuid, uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.forum_moderate_promo(uuid, uuid, text, text) TO authenticated;
