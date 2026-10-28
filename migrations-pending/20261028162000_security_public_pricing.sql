-- Public commercial terms remain readable; provider options and credentials
-- are independently projected out by the REST gateway.
ALTER POLICY security_public_settings ON public.settings USING (key IN (
 'generation_price','max_lyrics_length','max_prompt_length','min_topup_amount',
 'max_topup_amount','commission_percent','deposit_price','site_name','site_description',
 'maintenance_enabled','cover_generation_price','platform_commission_percent',
 'label_commission_percent','subscriber_discount_percent','forum_voting_category_id','price_per_image'
));
ALTER TABLE public.addon_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
CREATE POLICY security_public_catalog_read ON public.addon_services FOR SELECT TO anon,authenticated USING(is_active IS TRUE);
CREATE POLICY security_public_catalog_admin ON public.addon_services TO authenticated USING(public.is_admin(auth.uid())) WITH CHECK(public.is_admin(auth.uid()));
CREATE POLICY security_public_catalog_read ON public.subscription_plans FOR SELECT TO anon,authenticated USING(is_active IS TRUE);
CREATE POLICY security_public_catalog_admin ON public.subscription_plans TO authenticated USING(public.is_admin(auth.uid())) WITH CHECK(public.is_admin(auth.uid()));
