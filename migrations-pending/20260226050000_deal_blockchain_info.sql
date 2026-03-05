-- RPC for admins to fetch deal blockchain info (tx_id, timestamp from purchase + lyrics_deposits)
CREATE OR REPLACE FUNCTION public.admin_get_deal_blockchain_info(p_purchase_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase RECORD;
  v_deposit RECORD;
  v_result JSONB;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: admin only';
  END IF;

  SELECT ip.blockchain_tx_id, ip.item_type, ip.source_id
  INTO v_purchase
  FROM public.item_purchases ip
  WHERE ip.id = p_purchase_id;

  IF v_purchase IS NULL THEN
    RETURN NULL;
  END IF;

  v_result := jsonb_build_object(
    'tx_id', v_purchase.blockchain_tx_id,
    'timestamp', NULL
  );

  IF v_purchase.item_type = 'lyrics' AND v_purchase.source_id IS NOT NULL THEN
    SELECT ld.deposited_at, ld.timestamp_hash, ld.external_id
    INTO v_deposit
    FROM public.lyrics_deposits ld
    WHERE ld.lyrics_id = v_purchase.source_id
      AND ld.method = 'blockchain'
      AND ld.status = 'completed'
    ORDER BY ld.deposited_at DESC NULLS LAST
    LIMIT 1;

    IF v_deposit IS NOT NULL THEN
      v_result := jsonb_build_object(
        'tx_id', COALESCE(v_purchase.blockchain_tx_id, v_deposit.external_id, v_deposit.timestamp_hash),
        'timestamp', v_deposit.deposited_at,
        'timestamp_hash', v_deposit.timestamp_hash,
        'external_id', v_deposit.external_id
      );
    END IF;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_deal_blockchain_info(UUID) TO authenticated;
