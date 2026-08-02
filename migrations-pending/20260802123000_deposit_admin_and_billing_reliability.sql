ALTER TABLE public.track_deposits
ADD COLUMN IF NOT EXISTS price_rub integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'track_deposits_price_rub_nonnegative'
      AND conrelid = 'public.track_deposits'::regclass
  ) THEN
    ALTER TABLE public.track_deposits
      ADD CONSTRAINT track_deposits_price_rub_nonnegative CHECK (price_rub >= 0);
  END IF;
END;
$$;

UPDATE public.track_deposits td
SET price_rub = ABS(bt.amount)::integer
FROM public.balance_transactions bt
WHERE bt.reference_id = td.id
  AND bt.reference_type = 'track_deposit'
  AND bt.type = 'track_deposit'
  AND bt.amount < 0
  AND td.price_rub = 0;

CREATE OR REPLACE FUNCTION public.get_deposit_method_catalog()
RETURNS TABLE(method text, price integer, available boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH configured AS (
    SELECT key, value
    FROM public.settings
    WHERE key IN (
      'deposit_price_blockchain', 'deposit_price_nris', 'deposit_price_irma',
      'nris_api_key', 'irma_api_key'
    )
  )
  SELECT catalog.method,
         CASE
           WHEN price_setting.value ~ '^\d+$' THEN price_setting.value::integer
           ELSE catalog.default_price
         END AS price,
         CASE
           WHEN catalog.api_key IS NULL THEN true
           ELSE EXISTS (
             SELECT 1 FROM configured key_setting
             WHERE key_setting.key = catalog.api_key
               AND btrim(key_setting.value) <> ''
           )
         END AS available
  FROM (VALUES
    ('blockchain'::text, 'deposit_price_blockchain'::text, 300, NULL::text),
    ('nris'::text, 'deposit_price_nris'::text, 500, 'nris_api_key'::text),
    ('irma'::text, 'deposit_price_irma'::text, 300, 'irma_api_key'::text)
  ) AS catalog(method, price_key, default_price, api_key)
  LEFT JOIN configured price_setting ON price_setting.key = catalog.price_key
  ORDER BY CASE catalog.method WHEN 'blockchain' THEN 1 WHEN 'nris' THEN 2 ELSE 3 END;
$$;

REVOKE ALL ON FUNCTION public.get_deposit_method_catalog() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_deposit_method_catalog() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.begin_track_deposit(
  p_deposit_id uuid,
  p_track_id uuid,
  p_user_id uuid,
  p_method text,
  p_file_hash text,
  p_metadata_hash text,
  p_performer_name text,
  p_lyrics_author text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track_title text;
  v_existing_status text;
  v_base_price integer := 0;
  v_effective_price integer := 0;
  v_free_total integer := 0;
  v_used integer := 0;
  v_balance_before numeric;
  v_balance_after numeric;
  v_price_value text;
BEGIN
  IF p_method NOT IN ('internal', 'pdf', 'blockchain', 'nris', 'irma') THEN
    RAISE EXCEPTION 'Неизвестный метод депонирования';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  SELECT title INTO v_track_title
  FROM public.tracks
  WHERE id = p_track_id AND user_id = p_user_id;

  IF v_track_title IS NULL THEN
    RAISE EXCEPTION 'Трек не найден или не принадлежит вам';
  END IF;

  SELECT status INTO v_existing_status
  FROM public.track_deposits
  WHERE track_id = p_track_id AND method = p_method
  FOR UPDATE;

  IF v_existing_status = 'completed' THEN
    RAISE EXCEPTION 'Трек уже депонирован этим методом';
  ELSIF v_existing_status IN ('pending', 'processing') THEN
    RAISE EXCEPTION 'Депонирование этим методом уже выполняется';
  ELSIF v_existing_status = 'failed' THEN
    DELETE FROM public.track_deposits
    WHERE track_id = p_track_id AND method = p_method AND status = 'failed';
  END IF;

  SELECT value INTO v_price_value
  FROM public.settings
  WHERE key = 'deposit_price_' || p_method;

  v_base_price := CASE
    WHEN v_price_value ~ '^\d+$' THEN v_price_value::integer
    WHEN p_method = 'blockchain' THEN 300
    WHEN p_method = 'nris' THEN 500
    WHEN p_method = 'irma' THEN 300
    ELSE 0
  END;
  v_effective_price := GREATEST(0, v_base_price);

  IF p_method = 'blockchain' THEN
    SELECT COALESCE(sp.deposits_free_monthly, 0)
    INTO v_free_total
    FROM public.user_subscriptions us
    JOIN public.subscription_plans sp ON sp.id = us.plan_id
    WHERE us.user_id = p_user_id
      AND us.status IN ('active', 'canceled')
      AND us.current_period_end > now()
    ORDER BY us.created_at DESC
    LIMIT 1;

    SELECT COALESCE(sum(source.used), 0)::integer
    INTO v_used
    FROM (
      SELECT count(*)::integer AS used
      FROM public.track_deposits
      WHERE user_id = p_user_id
        AND method = 'blockchain'
        AND status IN ('processing', 'completed')
        AND created_at >= date_trunc('month', now())
      UNION ALL
      SELECT count(*)::integer AS used
      FROM public.lyrics_deposits
      WHERE user_id = p_user_id
        AND method = 'blockchain'
        AND status IN ('pending', 'processing', 'completed')
        AND created_at >= date_trunc('month', now())
    ) source;

    IF v_used < v_free_total THEN
      v_effective_price := 0;
    END IF;
  END IF;

  SELECT balance INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_balance_before IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;
  IF v_balance_before < v_effective_price THEN
    RAISE EXCEPTION 'Недостаточно средств. Требуется: % ₽, баланс: % ₽',
      v_effective_price, v_balance_before;
  END IF;

  v_balance_after := v_balance_before - v_effective_price;

  INSERT INTO public.track_deposits (
    id, track_id, user_id, method, status, file_hash, metadata_hash,
    performer_name, lyrics_author, price_rub
  ) VALUES (
    p_deposit_id, p_track_id, p_user_id, p_method, 'processing', p_file_hash,
    p_metadata_hash, p_performer_name, p_lyrics_author, v_effective_price
  );

  IF v_effective_price > 0 THEN
    UPDATE public.profiles
    SET balance = v_balance_after
    WHERE user_id = p_user_id;

    INSERT INTO public.balance_transactions (
      user_id, amount, balance_before, balance_after, type, description,
      reference_id, reference_type, metadata
    ) VALUES (
      p_user_id, -v_effective_price, v_balance_before, v_balance_after,
      'track_deposit', 'Депонирование трека «' || v_track_title || '» (' || p_method || ')',
      p_deposit_id, 'track_deposit',
      jsonb_build_object(
        'track_id', p_track_id,
        'track_title', v_track_title,
        'method', p_method,
        'tariff_free_deposit', false
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'deposit_id', p_deposit_id,
    'price', v_effective_price,
    'balance_before', v_balance_before,
    'balance_after', v_balance_after,
    'tariff_free_deposit', p_method = 'blockchain' AND v_effective_price = 0 AND v_used < v_free_total,
    'free_remaining', CASE
      WHEN p_method = 'blockchain' THEN GREATEST(0, v_free_total - v_used - 1)
      ELSE 0
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.begin_track_deposit(uuid, uuid, uuid, text, text, text, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_track_deposit(uuid, uuid, uuid, text, text, text, text, text)
TO service_role;

CREATE OR REPLACE FUNCTION public.fail_track_deposit_and_refund(
  p_deposit_id uuid,
  p_error_message text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deposit public.track_deposits%ROWTYPE;
  v_balance_before numeric;
  v_balance_after numeric;
  v_refunded boolean := false;
BEGIN
  SELECT * INTO v_deposit
  FROM public.track_deposits
  WHERE id = p_deposit_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('deposit_id', p_deposit_id, 'refunded', false, 'missing', true);
  END IF;
  IF v_deposit.status = 'completed' THEN
    RETURN jsonb_build_object('deposit_id', p_deposit_id, 'refunded', false, 'completed', true);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_deposit.user_id::text, 0));

  UPDATE public.track_deposits
  SET status = 'failed',
      error_message = left(COALESCE(p_error_message, 'Unknown error'), 2000)
  WHERE id = p_deposit_id;

  IF v_deposit.price_rub > 0
     AND EXISTS (
       SELECT 1 FROM public.balance_transactions
       WHERE reference_id = p_deposit_id
         AND reference_type = 'track_deposit'
         AND type = 'track_deposit'
         AND amount < 0
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.balance_transactions
       WHERE reference_id = p_deposit_id
         AND reference_type = 'track_deposit'
         AND type = 'refund'
         AND amount > 0
     ) THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = v_deposit.user_id
    FOR UPDATE;

    IF v_balance_before IS NULL THEN
      RAISE EXCEPTION 'Профиль пользователя не найден для возврата';
    END IF;

    v_balance_after := v_balance_before + v_deposit.price_rub;

    UPDATE public.profiles
    SET balance = v_balance_after
    WHERE user_id = v_deposit.user_id;

    INSERT INTO public.balance_transactions (
      user_id, amount, balance_before, balance_after, type, description,
      reference_id, reference_type, metadata
    ) VALUES (
      v_deposit.user_id, v_deposit.price_rub, v_balance_before, v_balance_after,
      'refund', 'Возврат за неудачное депонирование трека',
      p_deposit_id, 'track_deposit',
      jsonb_build_object('track_id', v_deposit.track_id, 'method', v_deposit.method)
    );
    v_refunded := true;
  END IF;

  RETURN jsonb_build_object(
    'deposit_id', p_deposit_id,
    'refunded', v_refunded,
    'balance_after', v_balance_after
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fail_track_deposit_and_refund(uuid, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_track_deposit_and_refund(uuid, text)
TO service_role;

CREATE OR REPLACE FUNCTION public.get_admin_deposit_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  WITH days AS (
    SELECT generate_series(current_date - 29, current_date, interval '1 day')::date AS day
  ),
  daily AS (
    SELECT
      days.day,
      count(td.id)::integer AS total,
      count(td.id) FILTER (WHERE td.status = 'completed')::integer AS completed
    FROM days
    LEFT JOIN public.track_deposits td ON td.created_at::date = days.day
    GROUP BY days.day
    ORDER BY days.day
  ),
  methods AS (
    SELECT method, count(*)::integer AS total
    FROM public.track_deposits
    GROUP BY method
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM public.track_deposits),
    'completed', (SELECT count(*) FROM public.track_deposits WHERE status = 'completed'),
    'pending', (SELECT count(*) FROM public.track_deposits WHERE status IN ('pending', 'processing')),
    'failed', (SELECT count(*) FROM public.track_deposits WHERE status = 'failed'),
    'revenue', (SELECT COALESCE(sum(price_rub), 0) FROM public.track_deposits WHERE status = 'completed'),
    'by_method', COALESCE((SELECT jsonb_object_agg(method, total) FROM methods), '{}'::jsonb),
    'daily', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'date', to_char(day, 'YYYY-MM-DD'),
        'total', total,
        'completed', completed
      ) ORDER BY day)
      FROM daily
    ), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_deposit_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admin_deposit_stats() TO authenticated, service_role;

