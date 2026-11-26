ALTER TABLE public.tracks ADD COLUMN suno_authorized_at timestamptz;
UPDATE public.tracks t SET suno_authorized_at = o.created_at
FROM promotions.music_orders o WHERE t.user_id = o.user_id AND t.id = ANY(o.track_ids);

CREATE FUNCTION promotions.mark_suno_tracks_authorized()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  UPDATE public.tracks SET suno_authorized_at = NEW.created_at
  WHERE user_id = NEW.user_id AND id = ANY(NEW.track_ids);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION promotions.mark_suno_tracks_authorized() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER mark_suno_tracks_authorized AFTER INSERT ON promotions.music_orders
FOR EACH ROW EXECUTE FUNCTION promotions.mark_suno_tracks_authorized();

CREATE OR REPLACE FUNCTION public.register_suno_generation_task(p_user_id uuid, p_track_ids uuid[], p_task_id text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  track_order promotions.music_orders%ROWTYPE;
BEGIN
  IF p_task_id IS NULL OR p_task_id !~ '^[a-zA-Z0-9_-]{1,160}$' THEN RETURN false; END IF;
  UPDATE promotions.music_orders SET provider_task_id = p_task_id
  WHERE user_id = p_user_id
    AND track_ids = ARRAY(SELECT id FROM unnest(p_track_ids) AS t(id) ORDER BY id)
    AND dispatched_at IS NOT NULL AND closed_at IS NULL AND provider_task_id IS NULL
  RETURNING * INTO track_order;
  IF NOT FOUND THEN RETURN false; END IF;
  UPDATE public.tracks
  SET provider_task_id = p_task_id,
    description = concat_ws(E'\n\n', nullif(trim(regexp_replace(coalesce(description, ''),
    '\[task_id:[^\]]*\]', '', 'gi')), ''), '[task_id: ' || p_task_id || ']')
  WHERE user_id = p_user_id AND id = ANY(track_order.track_ids) AND status = 'processing';
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.expire_release_packages()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  UPDATE public.release_packages SET status = 'failed', lease_id = NULL, lease_until = NULL, updated_at = now(),
    error_message = 'Сборка прервалась. Запустите подготовку релиз-пакета повторно.'
  WHERE id IN (SELECT id FROM public.release_packages WHERE status = 'processing'
    AND (lease_until <= now() OR (lease_until IS NULL AND updated_at < now() - interval '30 minutes'))
    ORDER BY updated_at LIMIT 25 FOR UPDATE SKIP LOCKED)
$$;
