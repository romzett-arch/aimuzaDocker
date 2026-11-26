ALTER TABLE promotions.music_orders ADD COLUMN provider_task_id text;

CREATE FUNCTION public.register_suno_generation_task(p_user_id uuid, p_track_ids uuid[], p_task_id text)
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
  SET description = concat_ws(E'\n\n', nullif(trim(regexp_replace(coalesce(description, ''),
    '\[task_id:[^\]]*\]', '', 'gi')), ''), '[task_id: ' || p_task_id || ']')
  WHERE user_id = p_user_id AND id = ANY(track_order.track_ids) AND status = 'processing';
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.register_suno_generation_task(uuid,uuid[],text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_suno_generation_task(uuid,uuid[],text) TO service_role;

CREATE INDEX music_orders_dispatched_recovery ON promotions.music_orders(dispatched_at)
  WHERE dispatched_at IS NOT NULL AND closed_at IS NULL AND provider_task_id IS NULL;

CREATE FUNCTION public.expire_unconfirmed_suno_orders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  stale promotions.music_orders%ROWTYPE;
  expired integer := 0;
BEGIN
  FOR stale IN SELECT o.* FROM promotions.music_orders o
    WHERE o.dispatched_at < now() - interval '1 hour' AND o.closed_at IS NULL AND o.provider_task_id IS NULL
      AND EXISTS (SELECT FROM public.generation_logs l WHERE l.user_id = o.user_id
        AND l.request_id = o.request_id AND l.status = 'pending')
    ORDER BY o.dispatched_at LIMIT 25 FOR UPDATE OF o SKIP LOCKED
  LOOP
    PERFORM public.fail_suno_generation(stale.user_id, stale.track_ids,
      'Не удалось подтвердить запуск Suno. Оплата или бонус возвращены.');
    UPDATE promotions.music_orders SET closed_at = now()
    WHERE user_id = stale.user_id AND request_id = stale.request_id;
    expired := expired + 1;
  END LOOP;
  RETURN expired;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_unconfirmed_suno_orders() FROM PUBLIC, anon, authenticated, service_role;
