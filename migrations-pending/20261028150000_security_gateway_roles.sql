-- Additive security migration. No data or database object is dropped.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aimuza_gateway') THEN
    CREATE ROLE aimuza_gateway NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END $$;
ALTER ROLE aimuza_gateway NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
GRANT anon, authenticated, service_role TO aimuza_gateway;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
-- Service role is a trusted backend capability, never an end-user role.
ALTER ROLE service_role BYPASSRLS;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
ALTER TABLE public.email_verifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.email_verifications,public.schema_migration_history FROM anon,authenticated;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='settings' AND policyname='security_public_settings') THEN
  CREATE POLICY security_public_settings ON public.settings FOR SELECT TO anon,authenticated
   USING (key IN ('generation_price','max_lyrics_length','max_prompt_length','min_topup_amount','max_topup_amount','commission_percent','deposit_price','site_name','site_description','maintenance_enabled'));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='settings' AND policyname='security_admin_settings') THEN
  CREATE POLICY security_admin_settings ON public.settings TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.get_last_messages(p_conversation_ids uuid[])
RETURNS TABLE(conversation_id uuid,content text,created_at timestamptz,sender_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT ON(m.conversation_id) m.conversation_id,m.content,m.created_at,m.sender_id
 FROM public.messages m JOIN public.conversation_participants cp ON cp.conversation_id=m.conversation_id AND cp.user_id=auth.uid()
 WHERE m.conversation_id=ANY(p_conversation_ids) AND m.deleted_at IS NULL ORDER BY m.conversation_id,m.created_at DESC;
$$;
CREATE OR REPLACE FUNCTION public.get_unread_counts(p_user_id uuid)
RETURNS TABLE(conversation_id uuid,unread_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT cp.conversation_id,COUNT(m.id) FROM public.conversation_participants cp
 LEFT JOIN public.messages m ON m.conversation_id=cp.conversation_id AND m.sender_id<>auth.uid()
  AND m.created_at>COALESCE(cp.last_read_at,'1970-01-01'::timestamptz) AND m.deleted_at IS NULL
 WHERE cp.user_id=auth.uid() AND p_user_id=auth.uid() GROUP BY cp.conversation_id;
$$;
REVOKE EXECUTE ON FUNCTION public.get_last_messages(uuid[]),public.get_unread_counts(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_last_messages(uuid[]),public.get_unread_counts(uuid) TO authenticated,service_role;
