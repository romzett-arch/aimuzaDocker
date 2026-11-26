CREATE FUNCTION public.record_lyrics_deposit_with_promo(
  p_record_id uuid,p_lyrics_id uuid,p_user_id uuid,p_content_hash text,
  p_timestamp_signature text,p_external_id text,p_certificate_url text,
  p_author_name text,p_deposited_at timestamptz,p_work_title text,
  p_external_proof text,p_base_price integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  apply_promo boolean := false;
  receipt jsonb;
BEGIN
  -- Match the existing shared quota lock before selecting the promo source.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
  IF p_base_price > 0 AND NOT COALESCE((public.check_deposit_limit(p_user_id)->>'is_free')::boolean,false) THEN
    IF NOT promotions.reserve(p_user_id,'deposit',p_record_id) THEN
      RAISE EXCEPTION 'promo_unavailable';
    END IF;
    apply_promo := true;
  END IF;

  receipt := public.record_lyrics_blockchain_deposit(
    p_record_id,p_lyrics_id,p_user_id,p_content_hash,p_timestamp_signature,
    p_external_id,p_certificate_url,p_author_name,p_deposited_at,p_work_title,
    p_external_proof,CASE WHEN apply_promo THEN 0 ELSE p_base_price END
  );
  -- A successfully recorded certificate already provides a local timestamp.
  -- The existing proof status continues to track independent confirmation.
  IF apply_promo THEN PERFORM promotions.settle(p_user_id,'deposit',p_record_id,true); END IF;
  RETURN receipt || jsonb_build_object('promo_applied',apply_promo);
END $$;

REVOKE ALL ON FUNCTION public.record_lyrics_deposit_with_promo(
  uuid,uuid,uuid,text,text,text,text,text,timestamptz,text,text,integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_lyrics_deposit_with_promo(
  uuid,uuid,uuid,text,text,text,text,text,timestamptz,text,text,integer
) TO service_role;

