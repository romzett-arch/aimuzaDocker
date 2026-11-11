-- Capture referral attribution only as part of creating a new account.
ALTER TABLE auth.vkid_flows ADD COLUMN IF NOT EXISTS referral_code text;
ALTER TABLE auth.yandex_flows ADD COLUMN IF NOT EXISTS referral_code text;

INSERT INTO public.referral_settings(key, value)
VALUES ('program_enabled', 'true'), ('max_referrals_per_user', '100'),
       ('min_deposit_to_activate', '0'), ('bonus_per_deposit_percent', '10'),
       ('referrer_bonus', '0'), ('referee_bonus', '0')
ON CONFLICT (key) DO NOTHING;

UPDATE public.referral_settings SET value = '10', updated_at = now()
WHERE key = 'bonus_per_deposit_percent' AND value IS DISTINCT FROM '10';

CREATE OR REPLACE FUNCTION public.bind_referral_on_signup()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := lower(trim(NEW.raw_user_meta_data->>'signup_referral_code'));
  v_code_id uuid;
  v_referrer uuid;
  v_referral_id uuid;
  v_limit integer;
  v_today date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  IF v_code IS NULL OR v_code !~ '^[a-z0-9_-]{3,20}$' OR NOT EXISTS (
    SELECT 1 FROM public.referral_settings WHERE key='program_enabled' AND value IN ('true','1')
  ) THEN RETURN NEW; END IF;

  SELECT c.id, c.user_id INTO v_code_id, v_referrer
  FROM public.referral_codes c JOIN auth.users u ON u.id = c.user_id
  WHERE (lower(c.code) = v_code OR lower(c.custom_code) = v_code)
    AND u.email_confirmed_at IS NOT NULL AND u.raw_user_meta_data->>'deleted_at' IS NULL
  ORDER BY (lower(c.code) = v_code) DESC, c.id
  LIMIT 1 FOR UPDATE OF c;
  IF NOT FOUND OR v_referrer = NEW.id THEN RETURN NEW; END IF;

  SELECT CASE WHEN value ~ '^[0-9]{1,9}$' THEN value::integer END INTO v_limit
  FROM public.referral_settings WHERE key='max_referrals_per_user';
  IF COALESCE(v_limit, 0) <= 0 OR (
    SELECT count(*) FROM public.referrals WHERE referrer_id=v_referrer
  ) >= v_limit THEN RETURN NEW; END IF;

  INSERT INTO public.referrals(referrer_id,referee_id,referred_id,referral_code_id,source,status)
  VALUES(v_referrer,NEW.id,NEW.id,v_code_id,COALESCE(NEW.raw_user_meta_data->>'provider','email'),'pending')
  ON CONFLICT(referee_id) DO NOTHING RETURNING id INTO v_referral_id;
  IF v_referral_id IS NULL THEN RETURN NEW; END IF;
  UPDATE public.referral_codes SET uses_count=COALESCE(uses_count,0)+1, updated_at=now() WHERE id=v_code_id;
  INSERT INTO public.referral_stats(user_id,date,registrations) VALUES(v_referrer,v_today,1)
  ON CONFLICT(user_id,date) DO UPDATE SET registrations=referral_stats.registrations+1,updated_at=now();
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.bind_referral_on_signup() FROM PUBLIC;
CREATE TRIGGER bind_referral_on_signup
AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.bind_referral_on_signup();

-- Retire the client registration entry point and the previous reward schedule.
CREATE OR REPLACE FUNCTION public.register_referral(p_referee_id uuid,p_referral_code text,
  p_ip_address text DEFAULT NULL,p_user_agent text DEFAULT NULL,p_source text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SET search_path = public AS $$
  SELECT jsonb_build_object('success',false,'error','signup_required')
$$;
REVOKE EXECUTE ON FUNCTION public.activate_referral(uuid,uuid) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.process_referral_deposit_bonus(uuid,uuid) FROM service_role;

-- The trusted payment function writes one topup ledger entry after crediting
-- the wallet. A refund reverses the linked bonus, even while paused.
CREATE OR REPLACE FUNCTION public.apply_referral_payment_bonus()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_referral public.referrals%ROWTYPE;
  v_reward public.referral_rewards%ROWTYPE;
  v_min numeric;
  v_evidence uuid;
  v_bonus integer;
  v_balance integer;
  v_today date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  SELECT * INTO v_payment FROM public.payments
  WHERE id=NEW.reference_id AND user_id=NEW.user_id AND payment_system='robokassa';
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT * INTO v_referral FROM public.referrals WHERE referee_id=NEW.user_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF NEW.type='refund' THEN
    IF v_payment.status <> 'refunded' OR NEW.amount <> -v_payment.amount THEN RETURN NEW; END IF;
    UPDATE public.referral_rewards AS r SET status='cancelled',updated_at=now()
    FROM public.referral_payment_evidence AS e
    WHERE r.evidence_id=e.id AND r.referral_id=v_referral.id AND r.status='paid'
      AND r.source_event='first_robokassa_topup' AND e.provider='robokassa'
      AND e.provider_payment_id=v_payment.id::text
    RETURNING r.* INTO v_reward;
    IF NOT FOUND THEN RETURN NEW; END IF;
    UPDATE public.profiles SET balance=balance-v_reward.amount
    WHERE user_id=v_reward.user_id RETURNING balance INTO v_balance;
    INSERT INTO public.balance_transactions
      (user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after,metadata)
    VALUES(v_reward.user_id,-v_reward.amount,'referral_bonus','Отмена реферального бонуса',
      'referral',v_referral.id,v_balance+v_reward.amount,v_balance,jsonb_build_object('payment_id',v_payment.id));
    UPDATE public.referrals SET status='pending',activated_at=NULL,activation_evidence_id=NULL,updated_at=now()
    WHERE id=v_referral.id AND activation_evidence_id=v_reward.evidence_id;
    UPDATE public.referral_stats SET activations=GREATEST(0,activations-1),earnings=earnings-v_reward.amount,updated_at=now()
    WHERE user_id=v_reward.user_id AND date=(v_reward.created_at AT TIME ZONE 'Europe/Moscow')::date;
    RETURN NEW;
  END IF;

  IF v_payment.status <> 'completed' OR NEW.amount <> v_payment.amount
     OR v_referral.status IS DISTINCT FROM 'pending' OR NOT EXISTS (
       SELECT 1 FROM public.referral_settings WHERE key='program_enabled' AND value IN ('true','1')
     ) THEN RETURN NEW; END IF;
  SELECT CASE WHEN value ~ '^[0-9]{1,9}([.][0-9]{1,2})?$' THEN value::numeric END INTO v_min
  FROM public.referral_settings WHERE key='min_deposit_to_activate';
  v_bonus := floor(v_payment.amount::numeric / 10)::integer;
  IF v_bonus <= 0 OR v_payment.amount < COALESCE(v_min,0) THEN RETURN NEW; END IF;

  UPDATE public.profiles SET balance=COALESCE(balance,0)+v_bonus
  WHERE user_id=v_referral.referrer_id RETURNING balance INTO v_balance;
  IF NOT FOUND THEN RETURN NEW; END IF;
  INSERT INTO public.referral_payment_evidence(provider,provider_payment_id,referee_id,amount,currency)
  VALUES('robokassa',v_payment.id::text,NEW.user_id,v_payment.amount,'RUB') RETURNING id INTO v_evidence;
  INSERT INTO public.referral_rewards(referral_id,user_id,type,amount,status,description,source_event,evidence_id,idempotency_key)
  VALUES(v_referral.id,v_referral.referrer_id,'deposit_percent',v_bonus,'paid',
    '10% от первого пополнения','first_robokassa_topup',v_evidence,'deposit:'||v_evidence);
  INSERT INTO public.balance_transactions
    (user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after,metadata)
  VALUES(v_referral.referrer_id,v_bonus,'referral_bonus','10% от первого пополнения реферала',
    'referral',v_referral.id,v_balance-v_bonus,v_balance,jsonb_build_object('payment_id',v_payment.id));
  UPDATE public.referrals SET status='active',activated_at=now(),activation_evidence_id=v_evidence,updated_at=now()
  WHERE id=v_referral.id;
  INSERT INTO public.referral_stats(user_id,date,activations,earnings)
  VALUES(v_referral.referrer_id,v_today,1,v_bonus)
  ON CONFLICT(user_id,date) DO UPDATE SET activations=referral_stats.activations+1,
    earnings=referral_stats.earnings+excluded.earnings,updated_at=now();
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.apply_referral_payment_bonus() FROM PUBLIC;
CREATE TRIGGER apply_referral_payment_bonus
AFTER INSERT ON public.balance_transactions
FOR EACH ROW WHEN (NEW.reference_type='payment' AND NEW.type IN ('topup','refund'))
EXECUTE FUNCTION public.apply_referral_payment_bonus();
