ALTER TABLE public.user_audio_references ALTER COLUMN expires_at SET DEFAULT now()+interval '1 day';
CREATE FUNCTION public.media_reference_ttl() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 NEW.uploaded_at:=CASE WHEN TG_OP='INSERT' THEN now() ELSE OLD.uploaded_at END;
 NEW.expires_at:=LEAST(COALESCE(NEW.expires_at,NEW.uploaded_at+interval '1 day'),NEW.uploaded_at+interval '1 day');
 RETURN NEW;
END $$;
CREATE TRIGGER media_reference_ttl BEFORE INSERT OR UPDATE ON public.user_audio_references
 FOR EACH ROW EXECUTE FUNCTION public.media_reference_ttl();

-- Legacy distribution requests must remain protected even if the track status drifted.
CREATE FUNCTION public.media_distribution_delete_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM distribution_requests WHERE track_id=OLD.id AND status NOT IN ('rejected','cancelled','failed')) THEN
  RAISE EXCEPTION 'Сначала отмените дистрибуцию / связь с релизом и снимите метку «В релиз»';
 END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER media_distribution_delete_guard BEFORE DELETE ON public.tracks
 FOR EACH ROW EXECUTE FUNCTION public.media_distribution_delete_guard();
REVOKE ALL ON FUNCTION public.media_reference_ttl(),public.media_distribution_delete_guard() FROM PUBLIC,anon,authenticated;
