ALTER TABLE promotions.campaigns ADD COLUMN topup_budget_rub integer CHECK (topup_budget_rub > 0);
ALTER TABLE public.payments ADD COLUMN provider_paid_at timestamptz;

CREATE FUNCTION public.process_verified_payment_completion(
  p_payment_id uuid, p_expected_amount integer, p_provider_paid_at timestamptz DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF p_provider_paid_at IS NOT NULL THEN
    UPDATE public.payments SET provider_paid_at = p_provider_paid_at
    WHERE id = p_payment_id AND status = 'pending' AND amount = p_expected_amount
      AND p_provider_paid_at >= created_at - interval '1 minute'
      AND p_provider_paid_at <= now() + interval '1 minute';
  END IF;
  RETURN public.process_payment_completion(p_payment_id, p_expected_amount);
END;
$$;
REVOKE ALL ON FUNCTION public.process_verified_payment_completion(uuid,integer,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_verified_payment_completion(uuid,integer,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_create_promo_campaign(p_config jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  actor uuid := promotions.require_admin();
  reward record;
  new_campaign uuid;
  topup_percent integer;
  topup_budget integer;
  campaign_rewards jsonb := COALESCE(p_config->'rewards','{}');
BEGIN
  IF p_config ? 'topup_percent' THEN
    IF jsonb_typeof(p_config->'topup_percent') IS DISTINCT FROM 'number'
       OR (p_config->>'topup_percent') !~ '^(0|[1-9][0-9]?|100)$' OR campaign_rewards <> '{}' THEN
      RAISE EXCEPTION 'Укажите целый процент от 0 до 100 для кампании пополнения';
    END IF;
    topup_percent := (p_config->>'topup_percent')::integer;
    IF p_config ? 'topup_budget_rub' THEN
      IF jsonb_typeof(p_config->'topup_budget_rub') IS DISTINCT FROM 'number'
        OR (p_config->>'topup_budget_rub') !~ '^[1-9][0-9]{0,8}$' THEN
        RAISE EXCEPTION 'Укажите бюджет от 1 до 999 999 999 рублей';
      END IF;
      topup_budget := (p_config->>'topup_budget_rub')::integer;
    END IF;
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
    (title,rewards,image_resolution,starts_at,redeem_until,valid_days,activation_limit,created_by,topup_percent,topup_budget_rub)
  VALUES
    (btrim(p_config->>'title'),campaign_rewards,COALESCE(p_config->>'image_resolution','1K'),
     (p_config->>'starts_at')::timestamptz,(p_config->>'redeem_until')::timestamptz,
     (p_config->>'valid_days')::integer,(p_config->>'activation_limit')::integer,actor,topup_percent,topup_budget)
  RETURNING id INTO new_campaign;
  INSERT INTO promotions.admin_events(campaign_id,actor,action) VALUES (new_campaign,actor,'created');
  RETURN new_campaign;
END $$;

CREATE OR REPLACE FUNCTION public.create_promo_topup_payment(
  p_user uuid,p_amount integer,p_system text,p_description text,p_external_id text,p_method text,p_code text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  code_value text := upper(btrim(p_code));
  code promotions.codes%ROWTYPE;
  campaign promotions.campaigns%ROWTYPE;
  payment_id uuid;
  bonus integer;
  expires timestamptz := now() + interval '1 hour';
  campaign_reserved integer;
  code_reserved integer;
  budget_committed bigint;
BEGIN
  IF p_user IS NULL OR p_amount IS NULL OR p_amount NOT BETWEEN 10 AND 150000
     OR p_system IS NULL OR p_system NOT IN ('robokassa','yookassa') THEN
    RAISE EXCEPTION 'Некорректный платёж';
  END IF;
  IF NOT promotions.check_attempt(p_user) THEN RETURN jsonb_build_object('error','promo_attempt_limit'); END IF;
  code := promotions.find_code(promotions.code_digest(code_value),promotions.legacy_code_digest(code_value));
  IF code.id IS NULL OR (code.target_user_id IS NOT NULL AND code.target_user_id <> p_user) THEN
    RETURN jsonb_build_object('error','promo_invalid');
  END IF;

  -- Lock the campaign first across checkout, redemption and admin operations.
  SELECT * INTO campaign FROM promotions.campaigns WHERE id=code.campaign_id FOR UPDATE;
  SELECT * INTO code FROM promotions.codes WHERE id=code.id FOR UPDATE;
  IF campaign.topup_percent IS NULL THEN RETURN jsonb_build_object('error','promo_not_for_topup'); END IF;
  IF NOT campaign.active OR NOT code.active OR now() < campaign.starts_at OR now() >= campaign.redeem_until THEN
    RETURN jsonb_build_object('error','promo_unavailable');
  END IF;
  IF EXISTS (SELECT 1 FROM promotions.activations WHERE campaign_id=campaign.id AND user_id=p_user) THEN
    RETURN jsonb_build_object('error','promo_already_activated');
  END IF;

  SELECT count(DISTINCT c.user_id),count(DISTINCT c.user_id) FILTER (WHERE c.code_id=code.id)
  INTO campaign_reserved,code_reserved
  FROM promotions.topup_claims c JOIN public.payments p ON p.id=c.payment_id AND p.status='pending'
  WHERE c.campaign_id=campaign.id AND c.user_id<>p_user AND c.expires_at + interval '24 hours' > now()
    AND NOT EXISTS (SELECT 1 FROM promotions.activations a WHERE a.campaign_id=c.campaign_id AND a.user_id=c.user_id);
  IF campaign.activations+campaign_reserved >= campaign.activation_limit OR code.activations+code_reserved >= code.activation_limit THEN
    RETURN jsonb_build_object('error','promo_limit_reached');
  END IF;

  bonus := p_amount * campaign.topup_percent / 100;
  IF campaign.topup_budget_rub IS NOT NULL THEN
    SELECT coalesce(sum(committed), 0) INTO budget_committed
    FROM (
      SELECT max(reservations.amount) AS committed FROM (
        SELECT t.user_id, t.amount
        FROM promotions.topup_claims t JOIN public.payments p ON p.id = t.payment_id
        WHERE t.campaign_id = campaign.id
          AND (t.credited_at IS NOT NULL OR (p.status = 'pending' AND t.expires_at + interval '24 hours' > now()))
        UNION ALL SELECT p_user, bonus
      ) reservations GROUP BY reservations.user_id
    ) grouped;
    IF budget_committed > campaign.topup_budget_rub THEN
      RETURN jsonb_build_object('error','promo_budget_exhausted');
    END IF;
  END IF;
  INSERT INTO public.payments (user_id,amount,currency,status,payment_system,description,external_id,metadata)
  VALUES (p_user,p_amount,'RUB','pending',p_system,p_description,p_external_id,
    CASE WHEN p_method IS NOT NULL THEN jsonb_build_object('method',p_method) END)
  RETURNING id INTO payment_id;
  INSERT INTO promotions.topup_claims(payment_id,campaign_id,code_id,user_id,amount,percent,expires_at)
  VALUES (payment_id,campaign.id,code.id,p_user,bonus,campaign.topup_percent,expires);
  RETURN jsonb_build_object('payment_id',payment_id,'bonus_amount',bonus,'bonus_percent',campaign.topup_percent,'bonus_expires_at',expires);
END $$;

CREATE OR REPLACE FUNCTION promotions.settle_topup()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  claim promotions.topup_claims%ROWTYPE;
  campaign promotions.campaigns%ROWTYPE;
  award integer;
  new_balance integer;
BEGIN
  SELECT * INTO claim FROM promotions.topup_claims WHERE payment_id=NEW.id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT * INTO campaign FROM promotions.campaigns WHERE id=claim.campaign_id FOR UPDATE;

  IF NEW.status='completed' THEN
    IF claim.credited_at IS NOT NULL OR claim.expires_at + interval '24 hours' <= now()
      OR (NEW.provider_paid_at IS NOT NULL AND NEW.provider_paid_at >= claim.expires_at) THEN RETURN NEW; END IF;
    INSERT INTO promotions.activations(campaign_id,code_id,user_id,rewards,expires_at)
    VALUES (campaign.id,claim.code_id,claim.user_id,jsonb_build_object('balance',claim.amount),now())
    ON CONFLICT (campaign_id,user_id) DO NOTHING;
    IF NOT FOUND THEN RETURN NEW; END IF;
    UPDATE promotions.codes SET activations=activations+1 WHERE id=claim.code_id;
    UPDATE promotions.campaigns SET activations=activations+1 WHERE id=campaign.id;
    UPDATE promotions.topup_claims SET credited_at=now() WHERE payment_id=NEW.id;
    award := claim.amount;
  ELSE
    IF claim.credited_at IS NULL OR claim.reversed_at IS NOT NULL THEN RETURN NEW; END IF;
    UPDATE promotions.topup_claims SET reversed_at=now() WHERE payment_id=NEW.id;
    award := -claim.amount;
  END IF;

  IF award <> 0 THEN
    UPDATE public.profiles SET balance=COALESCE(balance,0)+award WHERE user_id=claim.user_id RETURNING balance INTO new_balance;
    IF NOT FOUND THEN RAISE EXCEPTION 'Профиль пользователя не найден'; END IF;
    INSERT INTO public.balance_transactions(user_id,amount,type,description,balance_before,balance_after,reference_type,reference_id)
    VALUES(claim.user_id,award,'bonus',CASE WHEN award>0 THEN 'Бонус за пополнение «' ELSE 'Отмена бонуса за пополнение «' END
      || campaign.title || '»',new_balance-award,new_balance,'promo_topup',NEW.id);
  END IF;
  RETURN NEW;
END $$;
