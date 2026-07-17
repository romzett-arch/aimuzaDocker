CREATE OR REPLACE FUNCTION public.record_lyrics_blockchain_deposit(
  p_record_id uuid,
  p_lyrics_id uuid,
  p_user_id uuid,
  p_content_hash text,
  p_timestamp_signature text,
  p_external_id text,
  p_certificate_url text,
  p_author_name text,
  p_deposited_at timestamptz,
  p_work_title text,
  p_external_proof text,
  p_base_price integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_free_total integer := 0;
  v_used integer := 0;
  v_effective_price integer;
  v_balance_before integer;
  v_balance_after integer;
BEGIN
  -- Serialize tariff quota and balance consumption for this user.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  IF NOT EXISTS (
    SELECT 1 FROM public.lyrics_items
    WHERE id = p_lyrics_id AND user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Текст не найден или нет доступа';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.lyrics_deposits
    WHERE lyrics_id = p_lyrics_id AND method = 'blockchain'
      AND status IN ('pending', 'processing', 'completed')
  ) THEN
    RAISE EXCEPTION 'Текст уже отправлен на блокчейн-депонирование';
  END IF;

  SELECT COALESCE(sp.deposits_free_monthly, 0)
  INTO v_free_total
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  SELECT COALESCE(sum(source.used), 0)::integer INTO v_used
  FROM (
    SELECT count(*)::integer AS used FROM public.track_deposits
    WHERE user_id = p_user_id AND method = 'blockchain'
      AND status IN ('processing', 'completed')
      AND created_at >= date_trunc('month', now())
    UNION ALL
    SELECT count(*)::integer AS used FROM public.lyrics_deposits
    WHERE user_id = p_user_id AND method = 'blockchain'
      AND status IN ('pending', 'processing', 'completed')
      AND created_at >= date_trunc('month', now())
  ) source;

  v_effective_price := CASE WHEN v_used < v_free_total THEN 0 ELSE GREATEST(0, p_base_price) END;
  SELECT balance INTO v_balance_before FROM public.profiles
  WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance_before IS NULL OR v_balance_before < v_effective_price THEN
    RAISE EXCEPTION 'Недостаточно средств. Требуется % ₽, баланс % ₽', v_effective_price, COALESCE(v_balance_before, 0);
  END IF;
  v_balance_after := v_balance_before - v_effective_price;
  UPDATE public.profiles SET balance = v_balance_after WHERE user_id = p_user_id;

  INSERT INTO public.lyrics_deposits (
    id, lyrics_id, user_id, method, status, content_hash, timestamp_hash,
    external_id, certificate_url, author_name, price_rub, deposited_at,
    evidence_version, work_title_snapshot, proof_status, external_proof
  ) VALUES (
    p_record_id, p_lyrics_id, p_user_id, 'blockchain', 'pending', p_content_hash,
    p_timestamp_signature, p_external_id, p_certificate_url, p_author_name,
    v_effective_price, p_deposited_at, 'aimuza-lyrics-v1', p_work_title,
    'pending_external', p_external_proof
  );

  IF v_effective_price > 0 THEN
    INSERT INTO public.balance_transactions (
      user_id, amount, balance_before, balance_after, type, description,
      reference_id, reference_type, metadata
    ) VALUES (
      p_user_id, -v_effective_price, v_balance_before, v_balance_after,
      'lyrics_deposit', 'Блокчейн-депонирование AIMUZA: «' || p_work_title || '»',
      p_record_id, 'lyrics_deposit',
      jsonb_build_object('lyrics_id', p_lyrics_id, 'method', 'blockchain', 'tariff_free_deposit', false)
    );
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    p_user_id, 'lyrics_deposited', 'Депонирование AIMUZA отправлено',
    'Цифровой отпечаток текста «' || p_work_title || '» отправлен в OpenTimestamps. AIMUZA сохранила доказательство; ожидается подтверждение Bitcoin.',
    'lyrics', p_lyrics_id
  );

  RETURN jsonb_build_object(
    'deposit_id', p_record_id,
    'price', v_effective_price,
    'tariff_free_deposit', v_effective_price = 0 AND v_used < v_free_total,
    'free_remaining', GREATEST(0, v_free_total - v_used - 1),
    'balance_after', v_balance_after,
    'status', 'pending',
    'proof_status', 'pending_external'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_lyrics_blockchain_deposit(
  uuid, uuid, uuid, text, text, text, text, text, timestamptz, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_lyrics_blockchain_deposit(
  uuid, uuid, uuid, text, text, text, text, text, timestamptz, text, text, integer
) TO service_role;
