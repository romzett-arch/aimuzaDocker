CREATE OR REPLACE FUNCTION public.admin_issue_promo_codes(p_campaign_id uuid, p_config jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  actor uuid := promotions.require_admin();
  campaign promotions.campaigns%ROWTYPE;
  mode text := p_config->>'mode';
  code_count integer := CASE WHEN mode = 'single' THEN (p_config->>'count')::integer ELSE 1 END;
  code_limit integer := CASE WHEN mode = 'public' THEN (p_config->>'limit')::integer ELSE 1 END;
  target uuid := CASE WHEN mode = 'personal' THEN NULLIF(p_config->>'target','')::uuid END;
  custom_code text := CASE WHEN mode = 'public' THEN NULLIF(upper(btrim(p_config->>'code')),'') END;
  new_code text;
  issued jsonb := '[]';
BEGIN
  SELECT * INTO campaign FROM promotions.campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF NOT FOUND OR campaign.redeem_until <= now() THEN RAISE EXCEPTION 'Кампания недоступна'; END IF;
  IF mode IS NULL OR mode NOT IN ('public','single','personal')
    OR code_count IS NULL OR code_count NOT BETWEEN 1 AND LEAST(500,campaign.activation_limit)
    OR code_limit IS NULL OR code_limit NOT BETWEEN 1 AND campaign.activation_limit THEN
    RAISE EXCEPTION 'Проверьте параметры выпуска кодов';
  END IF;
  IF mode = 'personal' AND (target IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id=target)) THEN
    RAISE EXCEPTION 'Аккаунт не найден';
  END IF;
  IF custom_code IS NOT NULL AND custom_code !~ '^[A-Z0-9][A-Z0-9-]{3,39}$' THEN
    RAISE EXCEPTION 'Код должен содержать от 4 до 40 латинских букв, цифр или дефисов';
  END IF;

  FOR i IN 1..code_count LOOP
    new_code := COALESCE(custom_code,'AIMUZA-' || upper(encode(public.gen_random_bytes(10),'hex')));
    -- The short and full brand spellings share the same suffix for issued codes.
    IF new_code ~ '^AIM(UZA)?-[A-F0-9]{20}$' THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('promo-suffix:' || right(new_code,20), 0));
      IF EXISTS (SELECT 1 FROM promotions.codes WHERE digest IN (
        encode(public.digest('AIM-' || right(new_code,20),'sha256'),'hex'),
        encode(public.digest('AIMUZA-' || right(new_code,20),'sha256'),'hex')
      )) THEN
        RAISE EXCEPTION 'Код уже существует. Введите другой код или повторите генерацию';
      END IF;
    END IF;
    INSERT INTO promotions.codes(campaign_id,digest,hint,mode,target_user_id,activation_limit)
    VALUES (campaign.id,encode(public.digest(new_code,'sha256'),'hex'),
            '…' || right(new_code,4),mode,target,code_limit)
    ON CONFLICT (digest) DO NOTHING;
    IF NOT FOUND THEN RAISE EXCEPTION 'Код уже существует. Введите другой код или повторите генерацию'; END IF;
    issued := issued || jsonb_build_array(new_code);
  END LOOP;
  INSERT INTO promotions.admin_events(campaign_id,actor,action,detail)
  VALUES (campaign.id,actor,'codes_issued',jsonb_build_object('mode',mode,'count',code_count));
  RETURN issued;
END $$;

CREATE OR REPLACE FUNCTION public.use_promo_code(p_code text, p_activate boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  member uuid := auth.uid();
  code promotions.codes%ROWTYPE;
  campaign promotions.campaigns%ROWTYPE;
  redemption promotions.activations%ROWTYPE;
  code_value text := upper(btrim(p_code));
  attempt_count integer;
  cash integer;
  old_balance integer;
  award jsonb;
BEGIN
  IF member IS NULL THEN RAISE EXCEPTION 'Требуется вход'; END IF;
  INSERT INTO promotions.attempts AS gate(user_id,window_started,attempts) VALUES (member,now(),1)
  ON CONFLICT (user_id) DO UPDATE SET
    window_started=CASE WHEN gate.window_started <= now()-interval '10 minutes' THEN now() ELSE gate.window_started END,
    attempts=CASE WHEN gate.window_started <= now()-interval '10 minutes' THEN 1 ELSE least(gate.attempts+1,30) END
  RETURNING attempts INTO attempt_count;
  IF attempt_count > 20 THEN RETURN jsonb_build_object('error','promo_attempt_limit'); END IF;

  IF code_value !~ '^[A-Z0-9][A-Z0-9-]{3,39}$' OR code_value IS NULL THEN
    RETURN jsonb_build_object('error','promo_invalid');
  END IF;

  SELECT * INTO code FROM promotions.codes WHERE digest=encode(public.digest(code_value,'sha256'),'hex');
  IF NOT FOUND AND code_value ~ '^AIMUZA-[A-F0-9]{20}$' THEN
    SELECT * INTO code FROM promotions.codes
    WHERE digest=encode(public.digest('AIM-' || right(code_value,20),'sha256'),'hex');
  END IF;
  IF NOT FOUND OR (code.target_user_id IS NOT NULL AND code.target_user_id <> member) THEN
    RETURN jsonb_build_object('error','promo_invalid');
  END IF;

  SELECT * INTO campaign FROM promotions.campaigns WHERE id=code.campaign_id FOR UPDATE;
  SELECT * INTO code FROM promotions.codes WHERE id=code.id FOR UPDATE;
  SELECT * INTO redemption FROM promotions.activations WHERE campaign_id=campaign.id AND user_id=member;
  IF FOUND THEN
    IF p_activate AND redemption.code_id=code.id THEN
      RETURN jsonb_build_object('title',campaign.title,'rewards',redemption.rewards,'expires_at',redemption.expires_at,'replayed',true);
    END IF;
    RETURN jsonb_build_object('error','promo_already_activated');
  END IF;
  IF NOT campaign.active OR NOT code.active OR now() < campaign.starts_at OR now() >= campaign.redeem_until THEN
    RETURN jsonb_build_object('error','promo_unavailable');
  END IF;
  IF campaign.activations >= campaign.activation_limit OR code.activations >= code.activation_limit THEN
    RETURN jsonb_build_object('error','promo_limit_reached');
  END IF;

  award := jsonb_build_object('title',campaign.title,'rewards',campaign.rewards,'valid_days',campaign.valid_days,
                              'image_resolution',campaign.image_resolution);
  IF NOT p_activate THEN RETURN award; END IF;

  INSERT INTO promotions.activations(campaign_id,code_id,user_id,rewards,expires_at)
  VALUES (campaign.id,code.id,member,campaign.rewards,now()+make_interval(days=>campaign.valid_days))
  RETURNING * INTO redemption;
  UPDATE promotions.codes SET activations=activations+1 WHERE id=code.id;
  UPDATE promotions.campaigns SET activations=activations+1 WHERE id=campaign.id;
  INSERT INTO promotions.grants(activation_id,kind,total,remaining)
  SELECT redemption.id,key,value::integer,value::integer FROM jsonb_each_text(campaign.rewards) WHERE key <> 'balance';
  cash := COALESCE((campaign.rewards->>'balance')::integer,0);
  IF cash > 0 THEN
    SELECT COALESCE(balance,0) INTO old_balance FROM public.profiles WHERE user_id=member FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Профиль пользователя не найден'; END IF;
    UPDATE public.profiles SET balance=old_balance+cash WHERE user_id=member;
    INSERT INTO public.balance_transactions(user_id,amount,type,description,balance_before,balance_after,reference_type,reference_id)
    VALUES (member,cash,'bonus','Промокод «' || campaign.title || '»',old_balance,old_balance+cash,'promo_activation',redemption.id);
  END IF;
  RETURN award || jsonb_build_object('expires_at',redemption.expires_at);
END $$;
