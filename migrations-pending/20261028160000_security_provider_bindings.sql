ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS provider_task_id text;
UPDATE public.tracks SET provider_task_id=substring(description from '\[task_id:[[:space:]]*([a-zA-Z0-9_-]+)\]')
 WHERE provider_task_id IS NULL AND suno_audio_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.security_protect_provider_binding()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE marker text; old_marker text; client_request boolean;
BEGIN
 marker:=substring(NEW.description from '\[task_id:[[:space:]]*([a-zA-Z0-9_-]+)\]');
 client_request:=COALESCE(current_setting('request.jwt.claim.role',true),'') IN ('anon','authenticated');
 IF client_request THEN
  IF TG_OP='INSERT' THEN
   IF marker IS NOT NULL OR NEW.provider_task_id IS NOT NULL THEN RAISE EXCEPTION 'provider_metadata_server_only'; END IF;
  ELSE
   old_marker:=substring(OLD.description from '\[task_id:[[:space:]]*([a-zA-Z0-9_-]+)\]');
   IF NEW.provider_task_id IS DISTINCT FROM OLD.provider_task_id OR (marker IS NOT NULL AND marker IS DISTINCT FROM old_marker)
    THEN RAISE EXCEPTION 'provider_metadata_server_only'; END IF;
  END IF;
 ELSE
  IF marker IS NOT NULL THEN NEW.provider_task_id:=marker; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER security_provider_binding BEFORE INSERT OR UPDATE ON public.tracks
 FOR EACH ROW EXECUTE FUNCTION public.security_protect_provider_binding();

-- A provider retries a crashed callback after the bounded processing lease.
CREATE OR REPLACE FUNCTION public.security_claim_wav_callback(p_task_id text)
RETURNS SETOF public.track_addons LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF (SELECT count(*) FROM track_addons WHERE wav_task_id=p_task_id AND status IN ('processing','callback_processing'))>1
  THEN RAISE EXCEPTION 'ambiguous_provider_task'; END IF;
 RETURN QUERY UPDATE track_addons SET status='callback_processing',updated_at=now()
 WHERE wav_task_id=p_task_id AND (status='processing' OR (status='callback_processing' AND updated_at<now()-interval '10 minutes'))
 RETURNING *;
END $$;
REVOKE ALL ON FUNCTION public.security_protect_provider_binding() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.security_claim_wav_callback(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.security_claim_wav_callback(text) TO service_role;
