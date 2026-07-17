-- A Silk release voting result is one user event, not two notifications.

CREATE OR REPLACE FUNCTION public.sync_silk_release_voting_result()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_release record;
  v_status text;
BEGIN
  IF OLD.moderation_status IS DISTINCT FROM 'voting'
     OR OLD.voting_result IS DISTINCT FROM 'pending'
     OR NEW.voting_result NOT IN (
       'approved', 'voting_approved', 'manual_override_approved',
       'rejected', 'manual_override_rejected'
     )
  THEN
    RETURN NEW;
  END IF;

  v_status := CASE
    WHEN NEW.voting_result IN ('approved', 'voting_approved', 'manual_override_approved') THEN 'approved'
    ELSE 'rejected'
  END;

  FOR v_release IN
    UPDATE public.silk_releases
    SET status = v_status,
        reviewed_at = now(),
        admin_note = CASE v_status
          WHEN 'approved' THEN 'Одобрено по итогам голосования сообщества'
          ELSE 'Отклонено по итогам голосования сообщества'
        END,
        updated_at = now()
    WHERE source_track_id = NEW.id AND status = 'voting'
    RETURNING id, user_id, title
  LOOP
    INSERT INTO public.silk_release_events(release_id, actor_id, event_type, from_status, to_status, payload)
    VALUES (v_release.id, auth.uid(), 'voting_resolved', 'voting', v_status,
      jsonb_build_object('track_id', NEW.id, 'voting_result', NEW.voting_result));
  END LOOP;

  RETURN NEW;
END;
$$;

-- The standard voting notification is retained, but routed to the release and
-- given combined copy. It is emitted after the track/release transaction has
-- reached its final state, so it is the only notification the artist receives.
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
  IF NEW.type NOT IN ('voting_result', 'track_approved')
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

  -- A bridge track is already inside the label workflow. The generic
  -- moderation prompt to submit it to a release is therefore misleading.
  IF NEW.type = 'track_approved' THEN RETURN NULL; END IF;

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
WHERE notification.type = 'track_approved'
  AND notification.target_type = 'track'
  AND notification.target_id = release.source_track_id;

DROP TRIGGER IF EXISTS route_silk_voting_result_notification_trigger ON public.notifications;
CREATE TRIGGER route_silk_voting_result_notification_trigger
BEFORE INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.route_silk_voting_result_notification();

-- Merge already-created pairs. Keep the release notification when it exists;
-- otherwise convert the track notification in place.
DO $$
DECLARE
  v_duplicate record;
  v_keep_id uuid;
  v_title text;
BEGIN
  FOR v_duplicate IN
    SELECT notification.id,
           notification.user_id,
           notification.target_id AS track_id,
           notification.message,
           notification.created_at,
           release.id AS release_id,
           release.title AS release_title,
           release.status AS release_status
    FROM public.notifications notification
    JOIN public.silk_releases release ON release.source_track_id = notification.target_id
    WHERE notification.type = 'voting_result'
      AND notification.target_type = 'track'
  LOOP
    SELECT notification.id INTO v_keep_id
    FROM public.notifications notification
    WHERE notification.user_id = v_duplicate.user_id
      AND notification.target_type = 'silk_release'
      AND notification.target_id = v_duplicate.release_id
      AND abs(extract(epoch FROM (notification.created_at - v_duplicate.created_at))) <= 5
    ORDER BY abs(extract(epoch FROM (notification.created_at - v_duplicate.created_at)))
    LIMIT 1;

    v_title := CASE v_duplicate.release_status
      WHEN 'approved' THEN '🎉 Голосование пройдено — релиз одобрен'
      WHEN 'rejected' THEN 'Голосование завершено — релиз отклонён'
      ELSE 'Голосование по релизу завершено'
    END;

    IF v_keep_id IS NOT NULL THEN
      UPDATE public.notifications
      SET type = 'voting_result',
          title = v_title,
          message = v_duplicate.message,
          link = '/?tab=my-releases',
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
            'status', v_duplicate.release_status,
            'track_id', v_duplicate.track_id,
            'release_title', v_duplicate.release_title,
            'combined_notification', true
          )
      WHERE id = v_keep_id;

      DELETE FROM public.notifications WHERE id = v_duplicate.id;
    ELSE
      UPDATE public.notifications
      SET target_type = 'silk_release',
          target_id = v_duplicate.release_id,
          title = v_title,
          link = '/?tab=my-releases',
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
            'status', v_duplicate.release_status,
            'track_id', v_duplicate.track_id,
            'release_title', v_duplicate.release_title,
            'combined_notification', true
          )
      WHERE id = v_duplicate.id;
    END IF;

    v_keep_id := NULL;
  END LOOP;
END;
$$;
