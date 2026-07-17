CREATE OR REPLACE FUNCTION public.admin_get_deal_blockchain_info(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase record;
  v_deposit record;
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

  IF v_purchase.item_type = 'lyrics' AND v_purchase.source_id IS NOT NULL THEN
    SELECT
      ld.id,
      ld.deposited_at,
      ld.timestamp_hash,
      ld.external_id,
      ld.status,
      ld.proof_status,
      ld.certificate_url
    INTO v_deposit
    FROM public.lyrics_deposits ld
    WHERE ld.lyrics_id = v_purchase.source_id
      AND ld.method = 'blockchain'
      AND ld.status IN ('pending', 'processing', 'completed')
    ORDER BY ld.created_at DESC
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'tx_id', COALESCE(v_purchase.blockchain_tx_id, v_deposit.external_id, v_deposit.timestamp_hash),
    'timestamp', v_deposit.deposited_at,
    'timestamp_hash', v_deposit.timestamp_hash,
    'external_id', v_deposit.external_id,
    'deposit_id', v_deposit.id,
    'status', v_deposit.status,
    'proof_status', v_deposit.proof_status,
    'certificate_url', v_deposit.certificate_url
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_deal_blockchain_info(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_deal_blockchain_info(uuid) TO authenticated, service_role;
