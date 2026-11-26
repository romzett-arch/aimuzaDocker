-- Music requests may contain two track variants. One success completes the
-- reservation; a failure returns it only after both variants are terminal.
CREATE FUNCTION promotions.follow_generation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF NEW.request_id IS NULL OR NEW.status NOT IN ('completed','failed') THEN RETURN NEW; END IF;
  PERFORM FROM promotions.uses
  WHERE user_id=NEW.user_id AND kind='music' AND operation_id=NEW.request_id AND status='reserved' FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.generation_logs
    WHERE user_id=NEW.user_id AND request_id=NEW.request_id AND status='completed') THEN
    PERFORM promotions.settle(NEW.user_id,'music',NEW.request_id,true);
  ELSIF NOT EXISTS (SELECT 1 FROM public.generation_logs
    WHERE user_id=NEW.user_id AND request_id=NEW.request_id AND status NOT IN ('completed','failed')) THEN
    PERFORM promotions.settle(NEW.user_id,'music',NEW.request_id,false);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER follow_promo_generation AFTER UPDATE OF status ON public.generation_logs
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION promotions.follow_generation();

CREATE FUNCTION promotions.follow_service()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE service_kind text := TG_ARGV[0];
BEGIN
  IF NEW.status IN ('completed','failed') THEN
    PERFORM promotions.settle(NEW.user_id,service_kind,
      CASE WHEN service_kind='release' THEN (to_jsonb(NEW)->>'track_id')::uuid ELSE NEW.id END,
      NEW.status='completed');
  END IF;
  RETURN NEW;
END $$;
ALTER TABLE public.image_generation_jobs ADD COLUMN promo_applied boolean NOT NULL DEFAULT false;
CREATE TRIGGER follow_promo_image AFTER UPDATE OF status ON public.image_generation_jobs
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION promotions.follow_service('image');
CREATE TRIGGER follow_promo_deposit AFTER UPDATE OF status ON public.track_deposits
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION promotions.follow_service('deposit');
CREATE TRIGGER follow_promo_release AFTER INSERT OR UPDATE OF status ON public.release_packages
FOR EACH ROW EXECUTE FUNCTION promotions.follow_service('release');

CREATE FUNCTION promotions.available(p_user uuid,p_kind text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT COALESCE(sum(g.remaining),0)::integer FROM promotions.grants g
  JOIN promotions.activations a ON a.id=g.activation_id
  WHERE a.user_id=p_user AND g.kind=p_kind AND a.expires_at>now() AND g.remaining>0
$$;

CREATE FUNCTION public.promo_release_access(p_user_id uuid,p_track_id uuid,p_reserve boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tracks WHERE id=p_track_id AND user_id=p_user_id
    AND coalesce(source_type,'generated')='generated' AND status='completed' AND audio_url IS NOT NULL) THEN
    RETURN false;
  END IF;
  IF p_reserve THEN RETURN promotions.reserve(p_user_id,'release',p_track_id); END IF;
  RETURN promotions.available(p_user_id,'release') > 0 OR EXISTS (
    SELECT 1 FROM promotions.uses WHERE user_id=p_user_id AND kind='release' AND operation_id=p_track_id
      AND status IN ('reserved','used')
  );
END $$;
CREATE FUNCTION public.get_my_promo_release_tracks()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT COALESCE(jsonb_agg(u.operation_id),'[]') FROM promotions.uses u
  JOIN public.tracks t ON t.id=u.operation_id AND t.user_id=u.user_id
  WHERE u.user_id=auth.uid() AND u.kind='release' AND u.status IN ('reserved','used')
$$;
REVOKE ALL ON FUNCTION public.promo_release_access(uuid,uuid,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promo_release_access(uuid,uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION public.get_my_promo_release_tracks() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_promo_release_tracks() TO authenticated;

-- Uploads use the existing serialized accounting path and free tariff first.

CREATE FUNCTION public.check_promo_track_upload_limit(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  quota jsonb := public.check_track_upload_limit(p_user_id);
  slots integer;
BEGIN
  IF quota->>'reason' = 'unauthorized' THEN RETURN quota; END IF;
  slots := promotions.available(p_user_id,'upload');
  quota := quota || jsonb_build_object('promo_remaining',slots,'promo_applied',false);
  IF slots > 0 AND (quota->>'reason'='purchase_required' OR (quota->>'pack_applied')::boolean) THEN
    quota := (quota - 'reason') || '{"can_upload":true,"price":0,"is_free":true,"pack_applied":false,"promo_applied":true}';
  END IF;
  RETURN quota;
END $$;
REVOKE ALL ON FUNCTION public.check_promo_track_upload_limit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_promo_track_upload_limit(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.consume_track_upload_charge(p_user_id uuid,p_track_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE quota jsonb;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success',false,'error','unauthorized');
  END IF;
  PERFORM public.acquire_track_upload_lock(p_user_id);
  -- Never reserve against an arbitrary UUID passed to the old record RPC.
  IF EXISTS (SELECT 1 FROM public.tracks WHERE id=p_track_id AND user_id=p_user_id AND source_type='uploaded')
     AND NOT EXISTS (SELECT 1 FROM public.user_track_uploads WHERE user_id=p_user_id AND track_id=p_track_id AND refunded_at IS NULL) THEN
    quota := public.check_promo_track_upload_limit(p_user_id);
    IF (quota->>'promo_applied')::boolean THEN
      IF NOT promotions.reserve(p_user_id,'upload',p_track_id) THEN
        RETURN jsonb_build_object('success',false,'error','promo_unavailable');
      END IF;
      INSERT INTO public.user_track_uploads(user_id,track_id,price_charged,is_free,pack_slot_used)
      VALUES (p_user_id,p_track_id,0,true,false);
      PERFORM promotions.settle(p_user_id,'upload',p_track_id,true);
      RETURN '{"success":true,"price_charged":0,"is_free":true,"promo_applied":true}';
    END IF;
  END IF;
  RETURN public.consume_track_upload_charge_unlocked(p_user_id,p_track_id);
END $$;

CREATE FUNCTION promotions.return_removed_upload()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE source_id uuid;
BEGIN
  UPDATE promotions.uses SET status='returned',closed_at=now()
  WHERE user_id=OLD.user_id AND kind='upload' AND operation_id=OLD.track_id AND status='used'
  RETURNING activation_id INTO source_id;
  IF FOUND THEN
    UPDATE promotions.grants SET remaining=remaining+1 WHERE activation_id=source_id AND kind='upload';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER return_promo_upload AFTER DELETE ON public.user_track_uploads
FOR EACH ROW EXECUTE FUNCTION promotions.return_removed_upload();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA promotions FROM PUBLIC, anon, authenticated, service_role;


-- A promo-backed generation request may be dispatched to the provider once.
ALTER TABLE promotions.uses ADD COLUMN dispatched_at timestamptz;
CREATE FUNCTION public.claim_promo_music(p_user_id uuid,p_track_ids uuid[],p_has_reference boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE operation uuid;
BEGIN
  SELECT u.operation_id INTO operation FROM promotions.uses u
  JOIN public.generation_logs l ON l.user_id=u.user_id AND l.request_id=u.operation_id
  WHERE u.user_id=p_user_id AND u.kind='music' AND l.track_id=ANY(p_track_ids)
  ORDER BY u.created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN true; END IF;
  IF p_has_reference OR cardinality(p_track_ids) IS DISTINCT FROM 2 OR 2 <> (
    SELECT count(DISTINCT track_id) FROM public.generation_logs
    WHERE user_id=p_user_id AND request_id=operation AND track_id=ANY(p_track_ids)
  ) THEN RETURN false; END IF;

  UPDATE promotions.uses SET dispatched_at=now()
  WHERE user_id=p_user_id AND kind='music' AND operation_id=operation
    AND status='reserved' AND dispatched_at IS NULL;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.claim_promo_music(uuid,uuid[],boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_promo_music(uuid,uuid[],boolean) TO service_role;

