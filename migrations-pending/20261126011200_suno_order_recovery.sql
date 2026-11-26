ALTER TABLE promotions.music_orders ADD COLUMN closed_at timestamptz;
CREATE INDEX music_orders_unclaimed_expiry ON promotions.music_orders(created_at)
  WHERE dispatched_at IS NULL AND closed_at IS NULL;

CREATE FUNCTION public.expire_unclaimed_suno_orders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  stale promotions.music_orders%ROWTYPE;
  expired integer := 0;
BEGIN
  FOR stale IN SELECT * FROM promotions.music_orders
    WHERE dispatched_at IS NULL AND closed_at IS NULL AND created_at < now() - interval '30 minutes'
    ORDER BY created_at LIMIT 25 FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM public.fail_suno_generation(stale.user_id, stale.track_ids,
      'Время запуска генерации истекло. Оплата или бонус возвращены.', true);
    UPDATE promotions.music_orders SET closed_at = now()
    WHERE user_id = stale.user_id AND request_id = stale.request_id;
    expired := expired + 1;
  END LOOP;
  RETURN expired;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_unclaimed_suno_orders() FROM PUBLIC, anon, authenticated, service_role;
