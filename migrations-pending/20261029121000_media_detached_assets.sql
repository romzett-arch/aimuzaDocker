-- These legacy media tables have no track FK, so ON DELETE CASCADE cannot clean them.
CREATE FUNCTION public.media_capture_related_assets() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 INSERT INTO media_cleanup_jobs(track_id,payload)
 SELECT OLD.id,to_jsonb(a) FROM audio_separations a WHERE track_id=OLD.id AND status IN ('completed','failed');
 DELETE FROM audio_separations WHERE track_id=OLD.id AND status IN ('completed','failed');
 INSERT INTO media_cleanup_jobs(track_id,payload)
 SELECT OLD.id,to_jsonb(h) FROM track_health_reports h WHERE track_id=OLD.id;
 DELETE FROM track_health_reports WHERE track_id=OLD.id;
 RETURN OLD;
END $$;
CREATE TRIGGER media_capture_related_assets BEFORE DELETE ON public.tracks
 FOR EACH ROW EXECUTE FUNCTION public.media_capture_related_assets();

-- In-flight paid separations may finish/refund after the track disappears.
-- Keep their state until terminal status, then enqueue all newly arrived outputs.
CREATE FUNCTION public.media_capture_late_separation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.status IN ('completed','failed') AND NOT EXISTS(SELECT 1 FROM tracks WHERE id=NEW.track_id) THEN
  INSERT INTO media_cleanup_jobs(track_id,payload) VALUES(NEW.track_id,to_jsonb(NEW));
  DELETE FROM audio_separations WHERE id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER media_capture_late_separation AFTER INSERT OR UPDATE ON public.audio_separations
 FOR EACH ROW EXECUTE FUNCTION public.media_capture_late_separation();

WITH detached AS (
 DELETE FROM public.audio_separations a WHERE status IN ('completed','failed')
 AND NOT EXISTS(SELECT 1 FROM public.tracks t WHERE t.id=a.track_id) RETURNING *
) INSERT INTO public.media_cleanup_jobs(track_id,payload) SELECT track_id,to_jsonb(detached) FROM detached;
WITH detached AS (
 DELETE FROM public.track_health_reports h WHERE NOT EXISTS(SELECT 1 FROM public.tracks t WHERE t.id=h.track_id) RETURNING *
) INSERT INTO public.media_cleanup_jobs(track_id,payload) SELECT track_id,to_jsonb(detached) FROM detached;

REVOKE ALL ON FUNCTION public.media_capture_related_assets(),public.media_capture_late_separation() FROM PUBLIC,anon,authenticated;
