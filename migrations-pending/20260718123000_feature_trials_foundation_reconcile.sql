-- Preserve the production feature-trial ledger as an additive compatibility object.
-- This migration is intentionally non-destructive and is a no-op where the table exists.

CREATE TABLE IF NOT EXISTS public.feature_trials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  feature text NOT NULL,
  uses_remaining integer DEFAULT 0,
  total_uses integer DEFAULT 0,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.feature_trials TO authenticated;
