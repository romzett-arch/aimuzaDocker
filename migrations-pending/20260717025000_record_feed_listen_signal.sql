-- Persist a positive taste signal after the global player records a meaningful listen.
CREATE OR REPLACE FUNCTION public.record_feed_listen(p_track_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  actor_id UUID := auth.uid();
BEGIN
  IF actor_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.user_listened_tracks (user_id, track_id)
  VALUES (actor_id, p_track_id)
  ON CONFLICT (user_id, track_id) DO NOTHING;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.record_feed_listen(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_feed_listen(UUID) TO anon;

