ALTER TABLE public.release_packages ADD COLUMN lease_id uuid, ADD COLUMN lease_until timestamptz;

CREATE FUNCTION public.begin_release_package(p_user_id uuid, p_track_id uuid, p_promo boolean, p_details jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  lease uuid := gen_random_uuid();
  current_package public.release_packages%ROWTYPE;
BEGIN
  PERFORM FROM public.tracks WHERE id = p_track_id AND user_id = p_user_id
    AND status = 'completed' AND audio_url IS NOT NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN 'denied'; END IF;

  SELECT * INTO current_package FROM public.release_packages WHERE track_id = p_track_id FOR UPDATE;
  IF current_package.lease_until > now() THEN RETURN 'processing'; END IF;
  IF p_promo AND NOT public.promo_release_access(p_user_id, p_track_id, true) THEN RETURN 'denied'; END IF;

  INSERT INTO public.release_packages(track_id, user_id, status, lease_id, lease_until,
    requested_title, requested_performer_name, requested_author_name, requested_genre,
    requested_cover_id, requested_has_lyrics, requested_include_deposit, requested_move_to_my_releases)
  VALUES(p_track_id, p_user_id, 'processing', lease, now() + interval '30 minutes',
    p_details->>'requested_title', p_details->>'requested_performer_name',
    p_details->>'requested_author_name', p_details->>'requested_genre',
    (p_details->>'requested_cover_id')::uuid, (p_details->>'requested_has_lyrics')::boolean,
    (p_details->>'requested_include_deposit')::boolean,
    coalesce((p_details->>'requested_move_to_my_releases')::boolean, false))
  ON CONFLICT (track_id) DO UPDATE SET status = 'processing', lease_id = EXCLUDED.lease_id,
    lease_until = EXCLUDED.lease_until, requested_title = EXCLUDED.requested_title,
    requested_performer_name = EXCLUDED.requested_performer_name, requested_author_name = EXCLUDED.requested_author_name,
    requested_genre = EXCLUDED.requested_genre, requested_cover_id = EXCLUDED.requested_cover_id,
    requested_has_lyrics = EXCLUDED.requested_has_lyrics, requested_include_deposit = EXCLUDED.requested_include_deposit,
    requested_move_to_my_releases = EXCLUDED.requested_move_to_my_releases, error_message = NULL, updated_at = now();
  RETURN lease::text;
END;
$$;
REVOKE ALL ON FUNCTION public.begin_release_package(uuid,uuid,boolean,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_release_package(uuid,uuid,boolean,jsonb) TO service_role;

CREATE INDEX release_package_lease_expiry ON public.release_packages(lease_until) WHERE status = 'processing';
CREATE FUNCTION public.expire_release_packages()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  UPDATE public.release_packages SET status = 'failed', lease_id = NULL, lease_until = NULL, updated_at = now(),
    error_message = 'Сборка прервалась. Запустите подготовку релиз-пакета повторно.'
  WHERE id IN (SELECT id FROM public.release_packages WHERE status = 'processing' AND lease_until <= now()
    ORDER BY lease_until LIMIT 25 FOR UPDATE SKIP LOCKED)
$$;
REVOKE ALL ON FUNCTION public.expire_release_packages() FROM PUBLIC, anon, authenticated, service_role;
