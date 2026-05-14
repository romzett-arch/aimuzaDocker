
-- Add service quotas column to subscription_plans
-- This JSONB column stores daily limits for each addon service included in the plan
-- Format: { "service_name": daily_limit } where -1 means unlimited, 0 means not included
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS service_quotas jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Add badge column for profile badges per plan
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS badge_emoji text DEFAULT NULL;

-- Add watermark control
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS no_watermark boolean NOT NULL DEFAULT false;

-- Add commercial license flag
ALTER TABLE public.subscription_plans
ADD COLUMN IF NOT EXISTS commercial_license boolean NOT NULL DEFAULT false;
