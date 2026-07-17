-- Bridge tracks are an implementation detail of the label voting workflow.
-- They must never enter the ordinary track moderation notification contour.

CREATE OR REPLACE FUNCTION public.normalize_silk_voting_bridge_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.source_type = 'uploaded'
     AND NEW.moderation_status = 'pending'
     AND NEW.is_release_candidate IS TRUE
     AND NEW.is_in_my_releases IS TRUE
     AND NEW.audio_url LIKE '/storage/v1/object/public/tracks/silk-releases/%'
  THEN
    NEW.moderation_status := 'none';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS normalize_silk_voting_bridge_track_trigger ON public.tracks;
CREATE TRIGGER normalize_silk_voting_bridge_track_trigger
BEFORE INSERT ON public.tracks
FOR EACH ROW
EXECUTE FUNCTION public.normalize_silk_voting_bridge_track();

CREATE OR REPLACE FUNCTION public.route_silk_voting_result_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_release record;
  v_track_id uuid;
BEGIN
  IF NEW.type NOT IN ('voting_result', 'track_approved', 'new_track_moderation')
     OR NEW.target_type <> 'track'
     OR NEW.target_id IS NULL
  THEN
    RETURN NEW;
  END IF;

  v_track_id := NEW.target_id;

  SELECT release.id, release.title, release.status
  INTO v_release
  FROM public.silk_releases release
  WHERE release.source_track_id = NEW.target_id
  ORDER BY release.updated_at DESC
  LIMIT 1;

  IF NOT FOUND THEN RETURN NEW; END IF;

  IF NEW.type IN ('track_approved', 'new_track_moderation') THEN RETURN NULL; END IF;

  NEW.target_type := 'silk_release';
  NEW.target_id := v_release.id;
  NEW.link := '/?tab=my-releases';
  NEW.title := CASE v_release.status
    WHEN 'approved' THEN '🎉 Голосование пройдено — релиз одобрен'
    WHEN 'rejected' THEN 'Голосование завершено — релиз отклонён'
    ELSE 'Голосование по релизу завершено'
  END;
  NEW.metadata := coalesce(NEW.metadata, '{}'::jsonb) || jsonb_build_object(
    'status', v_release.status,
    'track_id', v_track_id,
    'release_title', v_release.title,
    'combined_notification', true
  );

  RETURN NEW;
END;
$$;

DELETE FROM public.notifications notification
USING public.silk_releases release
WHERE notification.type = 'new_track_moderation'
  AND notification.target_type = 'track'
  AND notification.target_id = release.source_track_id;
