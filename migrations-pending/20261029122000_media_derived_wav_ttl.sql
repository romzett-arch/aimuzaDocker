-- WAV stems/normalization reports also need an explicit deadline, independent of reads.
ALTER TABLE public.audio_separations ADD COLUMN media_expires_at timestamptz;
ALTER TABLE public.track_health_reports ADD COLUMN media_expires_at timestamptz;
UPDATE public.audio_separations SET media_expires_at=now()+interval '3 days' WHERE status='completed';
UPDATE public.track_health_reports SET media_expires_at=now()+interval '3 days' WHERE normalized_audio_url IS NOT NULL;
CREATE FUNCTION public.media_derived_wav_ttl() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_TABLE_NAME='audio_separations' THEN
  IF NEW.status='completed' AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status OR OLD.result_urls IS DISTINCT FROM NEW.result_urls) THEN
   NEW.media_expires_at:=now()+interval '3 days';
  END IF;
 ELSE
  IF NEW.normalized_audio_url IS NOT NULL AND (TG_OP='INSERT' OR OLD.normalized_audio_url IS DISTINCT FROM NEW.normalized_audio_url) THEN
   NEW.media_expires_at:=now()+interval '3 days';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER media_derived_wav_ttl BEFORE INSERT OR UPDATE ON public.audio_separations
 FOR EACH ROW EXECUTE FUNCTION public.media_derived_wav_ttl();
CREATE TRIGGER media_derived_wav_ttl BEFORE INSERT OR UPDATE ON public.track_health_reports
 FOR EACH ROW EXECUTE FUNCTION public.media_derived_wav_ttl();
REVOKE ALL ON FUNCTION public.media_derived_wav_ttl() FROM PUBLIC,anon,authenticated;
