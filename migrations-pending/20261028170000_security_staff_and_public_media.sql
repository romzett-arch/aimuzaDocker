CREATE POLICY security_public_promo_videos ON public.promo_videos FOR SELECT TO anon,authenticated
 USING(is_public IS TRUE AND status='completed');
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['api_keys','ai_provider_settings','email_templates','error_logs','performance_alerts','distribution_logs'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tab);
  EXECUTE format('CREATE POLICY security_staff_only ON public.%I TO authenticated USING(public.is_admin(auth.uid())) WITH CHECK(public.is_admin(auth.uid()))',tab);
 END LOOP;
END $$;
ALTER TABLE public.impersonation_action_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY security_audit_admin_read ON public.impersonation_action_logs FOR SELECT TO authenticated USING(public.is_admin(auth.uid()));
CREATE POLICY security_audit_admin_append ON public.impersonation_action_logs FOR INSERT TO authenticated WITH CHECK(public.is_admin(auth.uid()));
