CREATE TABLE promotions.topup_claims (
  payment_id uuid PRIMARY KEY REFERENCES public.payments(id) ON DELETE CASCADE,
  campaign_id uuid NOT NULL REFERENCES promotions.campaigns(id),
  code_id uuid NOT NULL REFERENCES promotions.codes(id),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount integer NOT NULL CHECK (amount >= 0),
  percent integer NOT NULL CHECK (percent BETWEEN 0 AND 100),
  expires_at timestamptz NOT NULL,
  credited_at timestamptz,
  reversed_at timestamptz
);
CREATE INDEX ON promotions.topup_claims (campaign_id,expires_at);
REVOKE ALL ON promotions.topup_claims FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.admin_set_promo_topup_percent(p_campaign_id uuid,p_percent integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := promotions.require_admin();
BEGIN
  IF p_percent IS NULL OR p_percent NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'Укажите процент от 0 до 100';
  END IF;
  UPDATE promotions.campaigns SET topup_percent=p_percent WHERE id=p_campaign_id AND topup_percent IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Кампания пополнения не найдена'; END IF;
  INSERT INTO promotions.admin_events(campaign_id,actor,action,detail)
  VALUES (p_campaign_id,actor,'topup_percent_changed',jsonb_build_object('percent',p_percent));
END $$;

CREATE FUNCTION public.create_promo_topup_payment(
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
  WHERE c.campaign_id=campaign.id AND c.user_id<>p_user AND c.expires_at>now()
    AND NOT EXISTS (SELECT 1 FROM promotions.activations a WHERE a.campaign_id=c.campaign_id AND a.user_id=c.user_id);
  IF campaign.activations+campaign_reserved >= campaign.activation_limit OR code.activations+code_reserved >= code.activation_limit THEN
    RETURN jsonb_build_object('error','promo_limit_reached');
  END IF;

  bonus := p_amount * campaign.topup_percent / 100;
  INSERT INTO public.payments (user_id,amount,currency,status,payment_system,description,external_id,metadata)
  VALUES (p_user,p_amount,'RUB','pending',p_system,p_description,p_external_id,
    CASE WHEN p_method IS NOT NULL THEN jsonb_build_object('method',p_method) END)
  RETURNING id INTO payment_id;
  INSERT INTO promotions.topup_claims(payment_id,campaign_id,code_id,user_id,amount,percent,expires_at)
  VALUES (payment_id,campaign.id,code.id,p_user,bonus,campaign.topup_percent,expires);
  RETURN jsonb_build_object('payment_id',payment_id,'bonus_amount',bonus,'bonus_percent',campaign.topup_percent,'bonus_expires_at',expires);
END $$;

CREATE FUNCTION promotions.settle_topup()
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
    IF claim.credited_at IS NOT NULL OR claim.expires_at <= now() THEN RETURN NEW; END IF;
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

CREATE TRIGGER settle_promo_topup AFTER UPDATE OF status ON public.payments
FOR EACH ROW WHEN ((OLD.status='pending' AND NEW.status='completed') OR
  (OLD.status='completed' AND NEW.status='refunded'))
EXECUTE FUNCTION promotions.settle_topup();

REVOKE ALL ON FUNCTION promotions.settle_topup() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_promo_topup_payment(uuid,integer,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_promo_topup_payment(uuid,integer,text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.admin_set_promo_topup_percent(uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_promo_topup_percent(uuid,integer) TO authenticated;
