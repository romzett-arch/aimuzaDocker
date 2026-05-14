-- Auto-update warnings_count via trigger instead of client-side code
CREATE OR REPLACE FUNCTION public.update_warnings_count()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.forum_user_stats
  SET warnings_count = (
    SELECT count(*) FROM public.forum_warnings
    WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND is_active = true
  ),
  updated_at = now()
  WHERE user_id = COALESCE(NEW.user_id, OLD.user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_update_warnings_count
AFTER INSERT OR UPDATE OR DELETE ON public.forum_warnings
FOR EACH ROW
EXECUTE FUNCTION public.update_warnings_count();