-- Service-only transaction boundaries; a track row serializes reservation.
CREATE OR REPLACE FUNCTION public.security_reserve_wav(p_track_id uuid,p_charge boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE t record; a record; s record; before_balance integer; price integer;
BEGIN
 SELECT * INTO t FROM tracks WHERE id=p_track_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'track_not_found'; END IF;
 SELECT * INTO s FROM addon_services WHERE name='convert_wav';
 IF NOT FOUND THEN RAISE EXCEPTION 'service_not_found'; END IF;
 SELECT * INTO a FROM track_addons WHERE track_id=t.id AND addon_service_id=s.id ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
 IF a.id IS NOT NULL AND a.status IN ('pending','processing','callback_processing','completed') THEN
  RETURN jsonb_build_object('started',false,'addon_id',a.id,'status',a.status);
 END IF;
 price:=CASE WHEN p_charge THEN s.price_rub ELSE 0 END;
 IF price IS NULL OR price<0 THEN RAISE EXCEPTION 'invalid_price'; END IF;
 SELECT balance INTO before_balance FROM profiles WHERE user_id=t.user_id FOR UPDATE;
 IF before_balance IS NULL OR before_balance<price THEN RAISE EXCEPTION 'insufficient_balance'; END IF;
 IF a.id IS NULL THEN
  INSERT INTO track_addons(track_id,user_id,addon_service_id,status,metadata) VALUES(t.id,t.user_id,s.id,'pending',jsonb_build_object('wav_charge',price,'wav_settled',false)) RETURNING * INTO a;
 ELSE
  UPDATE track_addons SET status='pending',result_url=NULL,metadata=jsonb_build_object('wav_charge',price,'wav_settled',false),updated_at=now() WHERE id=a.id;
 END IF;
 IF price>0 THEN
  UPDATE profiles SET balance=balance-price WHERE user_id=t.user_id;
  INSERT INTO balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
  VALUES(t.user_id,-price,'addon_service','Конвертация в WAV','track_addon',a.id,before_balance,before_balance-price);
 END IF;
 RETURN jsonb_build_object('started',true,'addon_id',a.id,'charged',price);
END $$;


REVOKE ALL ON FUNCTION public.security_reserve_wav(uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.security_reserve_wav(uuid,boolean) TO service_role;
