BEGIN;

CREATE OR REPLACE FUNCTION public.radio_create_next_slot()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_config JSONB; v_max_slot INTEGER; v_open_count INTEGER; v_new_id UUID; v_minutes INTEGER;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'administrator access required' USING ERRCODE = '42501';
  END IF;
  SELECT value INTO v_config FROM public.radio_config WHERE key='auction';
  IF COALESCE((v_config->>'enabled')::BOOLEAN, true) = false THEN RETURN NULL; END IF;
  v_minutes := COALESCE((v_config->>'slot_duration_minutes')::INTEGER, 60);
  SELECT count(*) INTO v_open_count FROM public.radio_slots WHERE status IN ('open','bidding');
  IF v_open_count >= 2 THEN RETURN NULL; END IF;
  SELECT COALESCE(max(slot_number),0) INTO v_max_slot FROM public.radio_slots;
  INSERT INTO public.radio_slots(slot_number,starts_at,ends_at,status)
  VALUES(v_max_slot+1,now(),now()+make_interval(mins=>v_minutes),'open') RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.radio_create_next_slot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.radio_create_next_slot() TO authenticated;

-- Remove legacy permissive policies that exposed every user's listening and prediction history.
DROP POLICY IF EXISTS radio_listens_own ON public.radio_listens;
DROP POLICY IF EXISTS radio_predictions_own ON public.radio_predictions;

COMMIT;
