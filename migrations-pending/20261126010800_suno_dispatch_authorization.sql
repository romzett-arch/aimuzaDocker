CREATE TABLE promotions.music_orders (
  user_id uuid NOT NULL,
  request_id uuid NOT NULL,
  track_ids uuid[] NOT NULL,
  provider_operation text NOT NULL CHECK (provider_operation IN ('generate', 'upload_cover')),
  amount_paid integer NOT NULL CHECK (amount_paid >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  dispatched_at timestamptz,
  PRIMARY KEY (user_id, request_id)
);

ALTER FUNCTION public.debit_for_generation_v6(uuid,uuid[],text,uuid,uuid[],text,jsonb)
  RENAME TO debit_generation_v6_unchecked_dispatch;
REVOKE ALL ON FUNCTION public.debit_generation_v6_unchecked_dispatch(uuid,uuid[],text,uuid,uuid[],text,jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.debit_for_generation_v6(
  p_user_id uuid,
  p_addon_service_ids uuid[] DEFAULT '{}',
  p_description text DEFAULT 'Генерация трека Suno V6',
  p_request_id uuid DEFAULT NULL,
  p_track_ids uuid[] DEFAULT '{}',
  p_provider_operation text DEFAULT 'generate',
  p_generation_params jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(new_balance integer, amount_debited integer, generation_service_id uuid,
  generation_sale_price_rub integer, generation_base_cost_credits numeric, discount_amount integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  billing record;
  track_count integer := coalesce(cardinality(p_track_ids), 0);
BEGIN
  IF track_count > 0 THEN
    IF p_request_id IS NULL OR track_count <> 2 OR p_provider_operation IS NULL THEN
      RAISE EXCEPTION 'invalid_generation_order';
    END IF;

    -- Track locks serialize billing across different request IDs for the same pair.
    PERFORM id FROM public.tracks
    WHERE id = ANY(p_track_ids) AND user_id = p_user_id
      AND status = 'pending' AND coalesce(source_type, 'generated') = 'generated'
    ORDER BY id FOR UPDATE;
    IF (SELECT count(*) FROM public.tracks WHERE id = ANY(p_track_ids) AND user_id = p_user_id
        AND status = 'pending' AND coalesce(source_type, 'generated') = 'generated') <> track_count
      OR EXISTS (SELECT FROM public.generation_logs WHERE track_id = ANY(p_track_ids)) THEN
      RAISE EXCEPTION 'invalid_generation_tracks';
    END IF;
  END IF;

  SELECT * INTO STRICT billing FROM public.debit_generation_v6_unchecked_dispatch(
    p_user_id, p_addon_service_ids, p_description, p_request_id, p_track_ids,
    p_provider_operation, p_generation_params
  );

  IF track_count > 0 THEN
    INSERT INTO promotions.music_orders(user_id, request_id, track_ids, provider_operation, amount_paid)
    VALUES (p_user_id, p_request_id, ARRAY(SELECT id FROM unnest(p_track_ids) AS t(id) ORDER BY id),
      p_provider_operation, billing.amount_debited);
  END IF;

  RETURN QUERY SELECT billing.new_balance, billing.amount_debited, billing.generation_service_id,
    billing.generation_sale_price_rub, billing.generation_base_cost_credits, billing.discount_amount;
END;
$$;

REVOKE ALL ON FUNCTION public.debit_for_generation_v6(uuid,uuid[],text,uuid,uuid[],text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.debit_for_generation_v6(uuid,uuid[],text,uuid,uuid[],text,jsonb) TO authenticated;

CREATE FUNCTION public.claim_suno_generation(p_user_id uuid, p_track_ids uuid[], p_operation text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  generation_order promotions.music_orders%ROWTYPE;
  ordered_tracks uuid[];
BEGIN
  IF cardinality(p_track_ids) IS DISTINCT FROM 2 OR p_track_ids[1] IS NULL
    OR p_track_ids[2] IS NULL OR p_track_ids[1] = p_track_ids[2] THEN
    RETURN false;
  END IF;
  ordered_tracks := ARRAY(SELECT id FROM unnest(p_track_ids) AS t(id) ORDER BY id);
  SELECT * INTO generation_order FROM promotions.music_orders
  WHERE user_id = p_user_id AND track_ids = ordered_tracks AND provider_operation = p_operation
    AND dispatched_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  PERFORM id FROM public.tracks WHERE id = ANY(ordered_tracks) AND user_id = p_user_id
    AND status = 'pending' ORDER BY id FOR UPDATE;
  IF (SELECT count(*) FROM public.tracks WHERE id = ANY(ordered_tracks) AND user_id = p_user_id
      AND status = 'pending') <> 2
    OR (SELECT count(DISTINCT track_id) FROM public.generation_logs
        WHERE user_id = p_user_id AND request_id = generation_order.request_id
          AND track_id = ANY(ordered_tracks) AND status = 'pending') <> 2 THEN
    RETURN false;
  END IF;

  IF generation_order.amount_paid = 0 THEN
    UPDATE promotions.uses SET dispatched_at = now()
    WHERE user_id = p_user_id AND kind = 'music' AND operation_id = generation_order.request_id
      AND status = 'reserved' AND dispatched_at IS NULL;
    IF NOT FOUND THEN RETURN false; END IF;
  END IF;

  UPDATE promotions.music_orders SET dispatched_at = now()
  WHERE user_id = p_user_id AND request_id = generation_order.request_id;
  UPDATE public.tracks SET status = 'processing', error_message = NULL
  WHERE user_id = p_user_id AND id = ANY(ordered_tracks);
  RETURN true;
END;
$$;

CREATE INDEX music_orders_pending_by_user ON promotions.music_orders (user_id, track_ids)
  WHERE dispatched_at IS NULL;
REVOKE ALL ON FUNCTION public.claim_suno_generation(uuid,uuid[],text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_suno_generation(uuid,uuid[],text) TO service_role;
REVOKE ALL ON FUNCTION public.claim_promo_music(uuid,uuid[],boolean) FROM service_role;

CREATE FUNCTION public.fail_suno_generation(
  p_user_id uuid, p_track_ids uuid[], p_error text, p_expire_unclaimed boolean DEFAULT false
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  generation_order promotions.music_orders%ROWTYPE;
  refund integer;
BEGIN
  SELECT * INTO generation_order FROM promotions.music_orders
  WHERE user_id = p_user_id AND track_ids = ARRAY(SELECT id FROM unnest(p_track_ids) AS t(id) ORDER BY id)
    AND CASE WHEN p_expire_unclaimed THEN dispatched_at IS NULL AND created_at < now() - interval '30 minutes'
      ELSE dispatched_at IS NOT NULL END
  FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;

  WITH failed AS (
    UPDATE public.generation_logs SET status = 'failed', refund_rub = cost_rub
    WHERE user_id = p_user_id AND request_id = generation_order.request_id
      AND track_id = ANY(generation_order.track_ids) AND status = 'pending'
    RETURNING cost_rub
  )
  SELECT coalesce(sum(cost_rub), 0)::integer INTO refund FROM failed;
  UPDATE public.tracks SET status = 'failed', error_message = p_error
  WHERE user_id = p_user_id AND id = ANY(generation_order.track_ids) AND status IN ('pending','processing');
  IF refund > 0 THEN
    PERFORM public.refund_generation_failed(p_user_id, refund, generation_order.track_ids[1],
      'Возврат за неудачную генерацию');
  END IF;
  RETURN refund;
END;
$$;
REVOKE ALL ON FUNCTION public.fail_suno_generation(uuid,uuid[],text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_suno_generation(uuid,uuid[],text,boolean) TO service_role;
