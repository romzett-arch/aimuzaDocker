-- Allow anonymous (unauthenticated) users to read pricing-related settings
-- Required for public /pricing page (Robokassa compliance: prices must be visible before auth)

CREATE POLICY "Public can view pricing settings"
ON public.settings FOR SELECT
USING (key IN (
  'generation_price',
  'cover_generation_price',
  'min_topup_amount',
  'platform_commission_percent',
  'subscriber_discount_percent',
  'min_beat_price',
  'min_payout_amount'
));
