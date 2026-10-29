-- Durable outbox: deletion and file cleanup intent commit together, including cascades.
CREATE TABLE public.media_cleanup_jobs (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 track_id uuid,
 payload jsonb NOT NULL,
 attempts integer NOT NULL DEFAULT 0,
 available_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(),
 last_error text
);
ALTER TABLE public.media_cleanup_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.media_cleanup_jobs FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.media_cleanup_jobs TO service_role;
GRANT USAGE ON SEQUENCE public.media_cleanup_jobs_id_seq TO service_role;
CREATE INDEX media_cleanup_jobs_due_idx ON public.media_cleanup_jobs(available_at,id);

CREATE FUNCTION public.media_capture_deleted_track() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE files jsonb;
BEGIN
 IF OLD.is_release_candidate IS TRUE
    OR COALESCE(OLD.distribution_status,'none') NOT IN ('none','rejected')
    OR EXISTS (SELECT 1 FROM silk_releases WHERE source_track_id=OLD.id)
 THEN RAISE EXCEPTION 'Сначала отмените дистрибуцию / связь с релизом и снимите метку «В релиз»'; END IF;
 SELECT jsonb_build_object('track',to_jsonb(OLD),
   'addons',COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM track_addons a WHERE track_id=OLD.id),'[]'),
   'packages',COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM release_packages p WHERE track_id=OLD.id),'[]'),
   'jobs',COALESCE((SELECT jsonb_agg(to_jsonb(j)) FROM audio_master_jobs j WHERE track_id=OLD.id),'[]')) INTO files;
 INSERT INTO media_cleanup_jobs(track_id,payload) VALUES(OLD.id,files);
 RETURN OLD;
END $$;
CREATE TRIGGER media_capture_deleted_track BEFORE DELETE ON public.tracks
 FOR EACH ROW EXECUTE FUNCTION public.media_capture_deleted_track();

-- Completion is the start of the retention period, never track creation time.
CREATE FUNCTION public.media_wav_completed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.status='completed' AND NEW.result_url IS NOT NULL
    AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status OR OLD.result_url IS DISTINCT FROM NEW.result_url)
    AND EXISTS (SELECT 1 FROM addon_services WHERE id=NEW.addon_service_id AND name='convert_wav') THEN
   NEW.metadata:=COALESCE(NEW.metadata,'{}')||jsonb_build_object('expires_at',now()+interval '3 days');
   UPDATE tracks SET wav_url=NEW.result_url,wav_expires_at=now()+interval '3 days' WHERE id=NEW.track_id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER media_wav_completed BEFORE INSERT OR UPDATE ON public.track_addons
 FOR EACH ROW EXECUTE FUNCTION public.media_wav_completed();

-- Existing downloadable WAVs get a full announced three-day grace period.
CREATE FUNCTION public.media_track_wav_ttl() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF (TG_OP='INSERT' AND (NEW.wav_url IS NOT NULL OR NEW.master_audio_url LIKE '%.wav' OR NEW.normalized_audio_url LIKE '%.wav'))
 OR (TG_OP='UPDATE' AND ((NEW.wav_url IS NOT NULL AND OLD.wav_url IS DISTINCT FROM NEW.wav_url)
 OR (NEW.master_audio_url LIKE '%.wav' AND OLD.master_audio_url IS DISTINCT FROM NEW.master_audio_url)
 OR (NEW.normalized_audio_url LIKE '%.wav' AND OLD.normalized_audio_url IS DISTINCT FROM NEW.normalized_audio_url))) THEN
  NEW.wav_expires_at:=now()+interval '3 days';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER media_track_wav_ttl BEFORE INSERT OR UPDATE ON public.tracks
 FOR EACH ROW EXECUTE FUNCTION public.media_track_wav_ttl();
UPDATE public.tracks SET wav_expires_at=now()+interval '3 days'
 WHERE wav_url IS NOT NULL OR master_audio_url LIKE '%.wav' OR normalized_audio_url LIKE '%.wav';
UPDATE public.track_addons a SET metadata=COALESCE(a.metadata,'{}')||jsonb_build_object('expires_at',now()+interval '3 days')
 FROM public.addon_services s WHERE a.addon_service_id=s.id AND s.name='convert_wav' AND a.status='completed';
UPDATE public.user_audio_references SET expires_at=uploaded_at+interval '1 day';

-- Canonical database inventory. Only media-bearing columns, never credentials.
-- New URL/path columns are included automatically. Missing/failed queries must stop cleanup.
CREATE FUNCTION public.media_live_references()
RETURNS TABLE(table_name text,row_id text,track_id text,payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r record; expr text;
BEGIN
 FOR r IN
  SELECT c.table_name, string_agg(format('%L,to_jsonb(t.%I)',c.column_name,c.column_name),',') AS cols
  FROM information_schema.columns c JOIN information_schema.tables t USING(table_schema,table_name)
  WHERE c.table_schema='public' AND t.table_type='BASE TABLE'
   AND (c.column_name LIKE '%url%' OR c.column_name LIKE '%path%' OR c.column_name='storage_bucket'
     OR (c.column_name IN ('metadata','vocal_separation_results','results') AND c.table_name IN ('tracks','track_addons','audio_master_jobs','silk_releases')))
   AND c.table_name NOT IN ('media_cleanup_jobs','error_logs','seo_bot_visits','ad_impressions')
  GROUP BY c.table_name
 LOOP
  expr:=format('SELECT %L, to_jsonb(t)->>''id'', COALESCE(to_jsonb(t)->>''track_id'',to_jsonb(t)->>''source_track_id''), jsonb_build_object(%s) FROM public.%I t',r.table_name,r.cols,r.table_name);
  RETURN QUERY EXECUTE expr;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.media_capture_deleted_track(), public.media_wav_completed(), public.media_live_references() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.media_track_wav_ttl() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.media_live_references() TO service_role;
