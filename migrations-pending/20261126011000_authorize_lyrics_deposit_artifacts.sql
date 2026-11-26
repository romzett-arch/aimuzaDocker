ALTER TABLE public.lyrics_deposits
  ADD COLUMN artifacts_pending boolean NOT NULL DEFAULT false,
  ADD COLUMN artifact_lease_id uuid,
  ADD COLUMN artifact_lease_until timestamptz;

CREATE INDEX lyrics_deposits_artifacts_pending ON public.lyrics_deposits(created_at)
  WHERE artifacts_pending;

CREATE FUNCTION public.begin_lyrics_deposit_artifacts(
  p_record_id uuid, p_lyrics_id uuid, p_user_id uuid, p_content_hash text,
  p_timestamp_signature text, p_external_id text, p_author_name text,
  p_deposited_at timestamptz, p_work_title text, p_use_promo boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  base_price integer;
  receipt jsonb;
BEGIN
  SELECT CASE WHEN value ~ '^[0-9]{1,9}$' THEN value::integer ELSE 300 END INTO base_price
  FROM public.settings WHERE key = 'deposit_price_blockchain';
  IF p_use_promo THEN
    receipt := public.record_lyrics_deposit_with_promo(
      p_record_id, p_lyrics_id, p_user_id, p_content_hash, p_timestamp_signature,
      p_external_id, NULL, p_author_name, p_deposited_at, p_work_title, NULL, coalesce(base_price, 300));
  ELSE
    receipt := public.record_lyrics_blockchain_deposit(
      p_record_id, p_lyrics_id, p_user_id, p_content_hash, p_timestamp_signature,
      p_external_id, NULL, p_author_name, p_deposited_at, p_work_title, NULL, coalesce(base_price, 300));
  END IF;
  UPDATE public.lyrics_deposits SET artifacts_pending = true WHERE id = p_record_id AND user_id = p_user_id;
  RETURN receipt;
END;
$$;

CREATE FUNCTION public.claim_lyrics_deposit_artifacts(p_deposit_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  UPDATE public.lyrics_deposits
  SET artifact_lease_id = gen_random_uuid(), artifact_lease_until = now() + interval '2 minutes'
  WHERE id = p_deposit_id AND user_id = p_user_id AND artifacts_pending
    AND (artifact_lease_until IS NULL OR artifact_lease_until <= now())
  RETURNING jsonb_build_object('lease', artifact_lease_id, 'evidence_id', external_id,
    'content_hash', content_hash, 'deposited_at', deposited_at, 'signature', timestamp_hash)
$$;

REVOKE ALL ON FUNCTION public.begin_lyrics_deposit_artifacts(uuid,uuid,uuid,text,text,text,text,timestamptz,text,boolean),
  public.claim_lyrics_deposit_artifacts(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_lyrics_deposit_artifacts(uuid,uuid,uuid,text,text,text,text,timestamptz,text,boolean),
  public.claim_lyrics_deposit_artifacts(uuid,uuid) TO service_role;
