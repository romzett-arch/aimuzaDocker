ALTER TABLE public.track_addons ADD COLUMN IF NOT EXISTS wav_task_id text;
UPDATE public.track_addons SET wav_task_id=substring(result_url from '"wav_task_id"[[:space:]]*:[[:space:]]*"([a-zA-Z0-9_-]+)"')
 WHERE wav_task_id IS NULL AND result_url LIKE '%"wav_task_id"%';
CREATE INDEX IF NOT EXISTS track_addons_wav_task_idx ON public.track_addons(wav_task_id) WHERE wav_task_id IS NOT NULL;
CREATE OR REPLACE FUNCTION public.security_claim_wav_callback(p_task_id text)
RETURNS SETOF public.track_addons LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 UPDATE public.track_addons SET status='callback_processing',updated_at=now()
 WHERE wav_task_id=p_task_id AND status='processing'
 RETURNING *;
$$;
CREATE OR REPLACE FUNCTION public.security_complete_wav(p_addon_id uuid,p_result_url text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 UPDATE track_addons SET status='completed',result_url=p_result_url,metadata=metadata||'{"wav_settled":true}'::jsonb,updated_at=now()
 WHERE id=p_addon_id AND status IN ('pending','processing','callback_processing') AND COALESCE(metadata->>'wav_settled','false')='false';
 RETURN FOUND;
END $$;
-- Include a claimed callback in the same idempotent failure transaction.
CREATE OR REPLACE FUNCTION public.security_fail_wav(p_addon_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE a record; price integer; before_balance integer;
BEGIN
 SELECT * INTO a FROM track_addons WHERE id=p_addon_id FOR UPDATE;
 IF NOT FOUND OR a.status NOT IN ('pending','processing','callback_processing') OR COALESCE((a.metadata->>'wav_settled')::boolean,false) THEN RETURN false; END IF;
 price:=COALESCE((a.metadata->>'wav_charge')::integer,0);
 IF price<0 THEN RAISE EXCEPTION 'invalid_charge'; END IF;
 IF price>0 THEN
  SELECT balance INTO before_balance FROM profiles WHERE user_id=a.user_id FOR UPDATE;
  IF before_balance IS NULL THEN RAISE EXCEPTION 'profile_not_found'; END IF;
  UPDATE profiles SET balance=balance+price WHERE user_id=a.user_id;
  INSERT INTO balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
  VALUES(a.user_id,price,'refund','Возврат за WAV','track_addon',a.id,before_balance,before_balance+price);
 END IF;
 UPDATE track_addons SET status='failed',metadata=metadata||'{"wav_settled":true}'::jsonb,updated_at=now() WHERE id=a.id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.security_claim_wav_callback(text),public.security_complete_wav(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.security_claim_wav_callback(text),public.security_complete_wav(uuid,text) TO service_role;
