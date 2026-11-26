-- Registration codes reuse regular campaign rewards. Top-up campaigns have a separate percentage.
ALTER TABLE promotions.campaigns ADD COLUMN topup_percent integer CHECK (topup_percent BETWEEN 0 AND 100);

CREATE FUNCTION promotions.check_attempt(p_member uuid)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE attempt_count integer;
BEGIN
  INSERT INTO promotions.attempts AS gate(user_id,window_started,attempts) VALUES (p_member,now(),1)
  ON CONFLICT (user_id) DO UPDATE SET
    window_started=CASE WHEN gate.window_started <= now()-interval '10 minutes' THEN now() ELSE gate.window_started END,
    attempts=CASE WHEN gate.window_started <= now()-interval '10 minutes' THEN 1 ELSE least(gate.attempts+1,30) END
  RETURNING attempts INTO attempt_count;
  RETURN attempt_count <= 20;
END $$;

CREATE FUNCTION promotions.find_code(p_digest text, p_legacy_digest text)
RETURNS promotions.codes LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT c FROM promotions.codes c WHERE c.digest IN (p_digest,p_legacy_digest)
  ORDER BY (c.digest = p_digest) DESC LIMIT 1;
$$;

CREATE FUNCTION promotions.code_digest(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN p_code ~ '^[A-Z0-9][A-Z0-9-]{3,39}$' THEN encode(public.digest(p_code,'sha256'),'hex') END;
$$;

CREATE FUNCTION promotions.legacy_code_digest(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN p_code ~ '^AIMUZA-[A-F0-9]{20}$' THEN promotions.code_digest('AIM-' || right(p_code,20)) END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_promo_campaign(p_config jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  actor uuid := promotions.require_admin();
  reward record;
  new_campaign uuid;
  topup_percent integer;
  campaign_rewards jsonb := COALESCE(p_config->'rewards','{}');
BEGIN
  IF p_config ? 'topup_percent' THEN
    IF jsonb_typeof(p_config->'topup_percent') IS DISTINCT FROM 'number'
       OR (p_config->>'topup_percent') !~ '^(0|[1-9][0-9]?|100)$' OR campaign_rewards <> '{}' THEN
      RAISE EXCEPTION 'Укажите целый процент от 0 до 100 для кампании пополнения';
    END IF;
    topup_percent := (p_config->>'topup_percent')::integer;
  ELSIF jsonb_typeof(campaign_rewards) IS DISTINCT FROM 'object' OR campaign_rewards = '{}' THEN
    RAISE EXCEPTION 'Укажите хотя бы один бонус';
  END IF;
  FOR reward IN SELECT * FROM jsonb_each_text(campaign_rewards) LOOP
    IF reward.key NOT IN ('music','image','deposit','release','upload','balance')
       OR reward.value IS NULL OR reward.value !~ '^[1-9][0-9]{0,5}$'
       OR (reward.key <> 'balance' AND reward.value::integer > 1000)
       OR (reward.key = 'balance' AND reward.value::integer > 100000) THEN
      RAISE EXCEPTION 'Недопустимое количество бонусов';
    END IF;
    IF jsonb_typeof(p_config->'rewards'->reward.key) <> 'number' THEN
      RAISE EXCEPTION 'Количество бонусов должно быть числом';
    END IF;
  END LOOP;
  INSERT INTO promotions.campaigns
    (title,rewards,image_resolution,starts_at,redeem_until,valid_days,activation_limit,created_by,topup_percent)
  VALUES
    (btrim(p_config->>'title'),campaign_rewards,COALESCE(p_config->>'image_resolution','1K'),
     (p_config->>'starts_at')::timestamptz,(p_config->>'redeem_until')::timestamptz,
     (p_config->>'valid_days')::integer,(p_config->>'activation_limit')::integer,actor,topup_percent)
  RETURNING id INTO new_campaign;
  INSERT INTO promotions.admin_events(campaign_id,actor,action) VALUES (new_campaign,actor,'created');
  RETURN new_campaign;
END $$;

CREATE FUNCTION promotions.redeem(p_member uuid, p_digest text, p_legacy_digest text, p_activate boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  member uuid := p_member;
  code promotions.codes%ROWTYPE;
  campaign promotions.campaigns%ROWTYPE;
  redemption promotions.activations%ROWTYPE;
  cash integer;
  old_balance integer;
  award jsonb;
BEGIN
  IF member IS NULL THEN RAISE EXCEPTION 'Требуется вход'; END IF;
  IF NOT promotions.check_attempt(member) THEN RETURN jsonb_build_object('error','promo_attempt_limit'); END IF;
  code := promotions.find_code(p_digest,p_legacy_digest);
  IF code.id IS NULL OR (code.target_user_id IS NOT NULL AND code.target_user_id <> member) THEN
    RETURN jsonb_build_object('error','promo_invalid');
  END IF;

  SELECT * INTO campaign FROM promotions.campaigns WHERE id=code.campaign_id FOR UPDATE;
  SELECT * INTO code FROM promotions.codes WHERE id=code.id FOR UPDATE;
  IF campaign.topup_percent IS NOT NULL THEN RETURN jsonb_build_object('error','promo_topup_only'); END IF;
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

CREATE OR REPLACE FUNCTION public.use_promo_code(p_code text, p_activate boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT promotions.redeem(auth.uid(),promotions.code_digest(upper(btrim(p_code))),
    promotions.legacy_code_digest(upper(btrim(p_code))),p_activate);
$$;

CREATE FUNCTION promotions.apply_signup_code()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  result jsonb;
BEGIN
  result := promotions.redeem(NEW.id,NEW.raw_user_meta_data->>'signup_promo_digest',
    NEW.raw_user_meta_data->>'signup_promo_legacy_digest',true);
  NEW.raw_user_meta_data := (NEW.raw_user_meta_data - 'signup_promo_digest' - 'signup_promo_legacy_digest')
    || jsonb_build_object('signup_promo_status',COALESCE(result->>'error','applied'));
  RETURN NEW;
END $$;

CREATE TRIGGER apply_signup_promo_code BEFORE UPDATE OF email_confirmed_at ON auth.users
FOR EACH ROW WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL
  AND NEW.raw_user_meta_data ? 'signup_promo_digest')
EXECUTE FUNCTION promotions.apply_signup_code();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA promotions FROM PUBLIC, anon, authenticated, service_role;
