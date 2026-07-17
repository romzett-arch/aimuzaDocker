-- Canonical reconciliation and security for Creator Economy, XP, achievements and referrals.
-- Safe to re-run.  No destructive data migration.

BEGIN;

-- ---------------------------------------------------------------------------
-- Canonical referral and achievement storage (preserve every legacy column).
-- ---------------------------------------------------------------------------
ALTER TABLE public.referral_codes
  ADD COLUMN IF NOT EXISTS custom_code text,
  ADD COLUMN IF NOT EXISTS views_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS clicks_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_user_id_uidx ON public.referral_codes(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_custom_code_uidx
  ON public.referral_codes(lower(custom_code)) WHERE custom_code IS NOT NULL;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS referee_id uuid,
  ADD COLUMN IF NOT EXISTS referral_code_id uuid,
  ADD COLUMN IF NOT EXISTS activated_at timestamptz,
  ADD COLUMN IF NOT EXISTS source text,
  ADD COLUMN IF NOT EXISTS ip_address text,
  ADD COLUMN IF NOT EXISTS user_agent text,
  ADD COLUMN IF NOT EXISTS activation_evidence_id uuid,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.referrals SET referee_id = referred_id
WHERE referee_id IS NULL AND referred_id IS NOT NULL;
UPDATE public.referrals SET referred_id = referee_id
WHERE referred_id IS NULL AND referee_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS referrals_referee_id_uidx ON public.referrals(referee_id);
CREATE INDEX IF NOT EXISTS referrals_referrer_created_idx ON public.referrals(referrer_id, created_at DESC);

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS source_event text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS evidence_id uuid,
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS referral_rewards_idempotency_uidx
  ON public.referral_rewards(idempotency_key) WHERE idempotency_key IS NOT NULL;

ALTER TABLE public.referral_settings ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.referral_stats
  ADD COLUMN IF NOT EXISTS date date,
  ADD COLUMN IF NOT EXISTS registrations integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS activations integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS earnings numeric(18,2) NOT NULL DEFAULT 0;
UPDATE public.referral_stats SET date = COALESCE(date, (updated_at AT TIME ZONE 'Europe/Moscow')::date);
ALTER TABLE public.referral_stats ALTER COLUMN date SET DEFAULT ((now() AT TIME ZONE 'Europe/Moscow')::date);
ALTER TABLE public.referral_stats ALTER COLUMN date SET NOT NULL;
ALTER TABLE public.referral_stats DROP CONSTRAINT IF EXISTS referral_stats_user_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS referral_stats_user_date_uidx ON public.referral_stats(user_id, date);

ALTER TABLE public.user_achievements
  ADD COLUMN IF NOT EXISTS earned_at timestamptz,
  ADD COLUMN IF NOT EXISTS unlocked_at timestamptz;
UPDATE public.user_achievements
SET earned_at = COALESCE(earned_at, unlocked_at, now()),
    unlocked_at = COALESCE(unlocked_at, earned_at, now());
ALTER TABLE public.user_achievements ALTER COLUMN earned_at SET DEFAULT now();
ALTER TABLE public.user_achievements ALTER COLUMN earned_at SET NOT NULL;

CREATE OR REPLACE FUNCTION public.sync_user_achievement_timestamps()
RETURNS trigger LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  NEW.earned_at := COALESCE(NEW.earned_at, NEW.unlocked_at, now());
  NEW.unlocked_at := COALESCE(NEW.unlocked_at, NEW.earned_at);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_sync_user_achievement_timestamps ON public.user_achievements;
CREATE TRIGGER trg_sync_user_achievement_timestamps
BEFORE INSERT OR UPDATE OF earned_at, unlocked_at ON public.user_achievements
FOR EACH ROW EXECUTE FUNCTION public.sync_user_achievement_timestamps();

-- Verified payment evidence is written by the payment service, never by clients.
CREATE TABLE IF NOT EXISTS public.referral_payment_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  provider_payment_id text NOT NULL,
  referee_id uuid NOT NULL,
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'AIPCI',
  verified_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(provider, provider_payment_id)
);
CREATE INDEX IF NOT EXISTS referral_payment_evidence_referee_idx
  ON public.referral_payment_evidence(referee_id, verified_at DESC);

-- ---------------------------------------------------------------------------
-- Referral RPCs.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_or_create_referral_code(uuid);
CREATE FUNCTION public.get_or_create_referral_code(p_user_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
        v_code text;
BEGIN
  IF v_caller IS NULL OR (v_caller <> p_user_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  SELECT code INTO v_code FROM public.referral_codes WHERE user_id=p_user_id;
  IF v_code IS NULL THEN
    LOOP
      v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
      BEGIN
        INSERT INTO public.referral_codes(user_id,code) VALUES(p_user_id,v_code);
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        SELECT code INTO v_code FROM public.referral_codes WHERE user_id=p_user_id;
        IF v_code IS NOT NULL THEN EXIT; END IF;
      END;
    END LOOP;
  END IF;
  UPDATE public.profiles SET referral_code=v_code
    WHERE user_id=p_user_id AND COALESCE(referral_code,'')='';
  RETURN v_code;
END $$;

CREATE OR REPLACE FUNCTION public.update_referral_settings(p_updates jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
        v_key text; v_value jsonb;
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION 'admin_required' USING ERRCODE='42501';
  END IF;
  IF jsonb_typeof(p_updates) <> 'object' THEN RAISE EXCEPTION 'updates_must_be_object'; END IF;
  FOR v_key,v_value IN SELECT key,value FROM jsonb_each(p_updates) LOOP
    IF v_key NOT IN ('referrer_bonus','referee_bonus','min_deposit_to_activate',
      'bonus_per_deposit_percent','max_referrals_per_user','program_enabled','levels') THEN
      RAISE EXCEPTION 'unsupported setting: %',v_key;
    END IF;
    INSERT INTO public.referral_settings(key,value,updated_at)
    VALUES(v_key, CASE WHEN jsonb_typeof(v_value)='string' THEN trim(both '"' from v_value::text) ELSE v_value::text END, now())
    ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at;
  END LOOP;
  RETURN jsonb_build_object('success',true,'updated',p_updates);
END $$;

CREATE OR REPLACE FUNCTION public.register_referral(p_referee_id uuid,p_referral_code text,
  p_ip_address text DEFAULT NULL,p_user_agent text DEFAULT NULL,p_source text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
        v_referrer uuid; v_code_id uuid; v_referral_id uuid; v_bonus integer := 0;
        v_before integer; v_today date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  IF v_caller IS NULL OR (v_caller<>p_referee_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  IF lower(COALESCE((SELECT value FROM public.referral_settings WHERE key='program_enabled'),'true')) <> 'true' THEN
    RETURN jsonb_build_object('success',false,'error','program_disabled');
  END IF;
  SELECT user_id,id INTO v_referrer,v_code_id FROM public.referral_codes
   WHERE upper(code)=upper(trim(p_referral_code)) OR lower(custom_code)=lower(trim(p_referral_code)) LIMIT 1;
  IF v_referrer IS NULL THEN RETURN jsonb_build_object('success',false,'error','code_not_found'); END IF;
  IF v_referrer=p_referee_id THEN RETURN jsonb_build_object('success',false,'error','self_referral'); END IF;
  INSERT INTO public.referrals(referrer_id,referee_id,referred_id,referral_code_id,source,ip_address,user_agent,status)
  VALUES(v_referrer,p_referee_id,p_referee_id,v_code_id,left(p_source,100),left(p_ip_address,128),left(p_user_agent,512),'pending')
  ON CONFLICT(referee_id) DO NOTHING RETURNING id INTO v_referral_id;
  IF v_referral_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','already_registered'); END IF;
  UPDATE public.referral_codes SET uses_count=COALESCE(uses_count,0)+1,updated_at=now() WHERE id=v_code_id;
  v_bonus := GREATEST(0,COALESCE((SELECT value::numeric::integer FROM public.referral_settings WHERE key='referee_bonus'),0));
  IF v_bonus>0 THEN
    UPDATE public.profiles SET balance=COALESCE(balance,0)+v_bonus WHERE user_id=p_referee_id
      RETURNING balance-v_bonus INTO v_before;
    INSERT INTO public.referral_rewards(referral_id,user_id,type,amount,status,description,source_event,idempotency_key)
    VALUES(v_referral_id,p_referee_id,'welcome_bonus',v_bonus,'paid','Бонус за регистрацию','registration','registration:'||v_referral_id);
    INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
    VALUES(p_referee_id,v_bonus,'referral_bonus','Бонус за регистрацию по реферальной ссылке','referral',v_referral_id,v_before,v_before+v_bonus);
  END IF;
  INSERT INTO public.referral_stats(user_id,date,registrations) VALUES(v_referrer,v_today,1)
  ON CONFLICT(user_id,date) DO UPDATE SET registrations=referral_stats.registrations+1,updated_at=now();
  RETURN jsonb_build_object('success',true,'referrer_id',v_referrer,'bonus_received',v_bonus);
END $$;

CREATE OR REPLACE FUNCTION public.activate_referral(p_referee_id uuid,p_payment_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_role text := current_setting('request.jwt.claim.role',true); v_ref public.referrals%ROWTYPE;
        v_ev public.referral_payment_evidence%ROWTYPE; v_bonus integer:=0; v_before integer;
        v_today date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  IF v_role IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_ev FROM public.referral_payment_evidence WHERE id=p_payment_evidence_id AND referee_id=p_referee_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','invalid_payment_evidence'); END IF;
  IF v_ev.amount < COALESCE((SELECT value::numeric FROM public.referral_settings WHERE key='min_deposit_to_activate'),0) THEN
    RETURN jsonb_build_object('success',false,'error','deposit_too_small'); END IF;
  SELECT * INTO v_ref FROM public.referrals WHERE referee_id=p_referee_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','referral_not_found'); END IF;
  IF v_ref.status='active' THEN RETURN jsonb_build_object('success',true,'already_processed',true,'bonus_paid',0); END IF;
  UPDATE public.referrals SET status='active',activated_at=now(),activation_evidence_id=p_payment_evidence_id,updated_at=now() WHERE id=v_ref.id;
  v_bonus:=GREATEST(0,COALESCE((SELECT value::numeric::integer FROM public.referral_settings WHERE key='referrer_bonus'),0));
  IF v_bonus>0 THEN
    UPDATE public.profiles SET balance=COALESCE(balance,0)+v_bonus WHERE user_id=v_ref.referrer_id RETURNING balance-v_bonus INTO v_before;
    INSERT INTO public.referral_rewards(referral_id,user_id,type,amount,status,description,source_event,evidence_id,idempotency_key)
    VALUES(v_ref.id,v_ref.referrer_id,'activation_bonus',v_bonus,'paid','Бонус за активацию реферала','activation',p_payment_evidence_id,'activation:'||v_ref.id)
    ON CONFLICT(idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING;
    INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
    VALUES(v_ref.referrer_id,v_bonus,'referral_bonus','Бонус за активацию реферала','referral',v_ref.id,v_before,v_before+v_bonus);
  END IF;
  INSERT INTO public.referral_stats(user_id,date,activations,earnings) VALUES(v_ref.referrer_id,v_today,1,v_bonus)
  ON CONFLICT(user_id,date) DO UPDATE SET activations=referral_stats.activations+1,earnings=referral_stats.earnings+excluded.earnings,updated_at=now();
  RETURN jsonb_build_object('success',true,'bonus_paid',v_bonus);
END $$;

CREATE OR REPLACE FUNCTION public.process_referral_deposit_bonus(p_referee_id uuid,p_payment_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_role text:=current_setting('request.jwt.claim.role',true); v_ref public.referrals%ROWTYPE;
        v_ev public.referral_payment_evidence%ROWTYPE; v_percent numeric; v_bonus integer; v_before integer;
        v_inserted uuid; v_today date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  IF v_role IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_ev FROM public.referral_payment_evidence WHERE id=p_payment_evidence_id AND referee_id=p_referee_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','invalid_payment_evidence'); END IF;
  SELECT * INTO v_ref FROM public.referrals WHERE referee_id=p_referee_id AND status='active';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','inactive_referral'); END IF;
  v_percent:=GREATEST(0,COALESCE((SELECT value::numeric FROM public.referral_settings WHERE key='bonus_per_deposit_percent'),0));
  v_bonus:=floor(v_ev.amount*v_percent/100)::integer;
  IF v_bonus<=0 THEN RETURN jsonb_build_object('success',true,'bonus_paid',0); END IF;
  INSERT INTO public.referral_rewards(referral_id,user_id,type,amount,status,description,source_event,evidence_id,idempotency_key)
  VALUES(v_ref.id,v_ref.referrer_id,'deposit_percent',v_bonus,'paid','Процент от депозита реферала','deposit',v_ev.id,'deposit:'||v_ev.id)
  ON CONFLICT(idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING RETURNING id INTO v_inserted;
  IF v_inserted IS NULL THEN RETURN jsonb_build_object('success',true,'already_processed',true,'bonus_paid',0); END IF;
  UPDATE public.profiles SET balance=COALESCE(balance,0)+v_bonus WHERE user_id=v_ref.referrer_id RETURNING balance-v_bonus INTO v_before;
  INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after,metadata)
  VALUES(v_ref.referrer_id,v_bonus,'referral_bonus','Процент от депозита реферала','referral',v_ref.id,v_before,v_before+v_bonus,jsonb_build_object('evidence_id',v_ev.id));
  INSERT INTO public.referral_stats(user_id,date,earnings) VALUES(v_ref.referrer_id,v_today,v_bonus)
  ON CONFLICT(user_id,date) DO UPDATE SET earnings=referral_stats.earnings+excluded.earnings,updated_at=now();
  RETURN jsonb_build_object('success',true,'bonus_paid',v_bonus);
END $$;

CREATE OR REPLACE FUNCTION public.get_my_referral_stats()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER STABLE SET search_path=public AS $$
  WITH me AS (SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid uid),
  totals AS (SELECT count(*) total,count(*) FILTER(WHERE status='active') active FROM public.referrals,me WHERE referrer_id=uid),
  earned AS (SELECT COALESCE(sum(amount),0) amount FROM public.referral_rewards,me WHERE user_id=uid AND status='paid'),
  today AS (SELECT COALESCE(sum(registrations),0) registrations,COALESCE(sum(activations),0) activations,COALESCE(sum(earnings),0) earnings
    FROM public.referral_stats,me WHERE user_id=uid AND date=(now() AT TIME ZONE 'Europe/Moscow')::date)
  SELECT jsonb_build_object('total_referrals',total,'active_referrals',active,'pending_referrals',total-active,
    'total_earnings',earned.amount,'today_registrations',today.registrations,'today_activations',today.activations,'today_earnings',today.earnings)
  FROM totals,earned,today
$$;

CREATE OR REPLACE FUNCTION public.get_referral_overview()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid; v_result jsonb;
BEGIN
 IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN RAISE EXCEPTION 'admin_required' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('total_referrals',count(*),'active_referrals',count(*) FILTER(WHERE status='active'),
  'pending_referrals',count(*) FILTER(WHERE status<>'active'),
  'total_paid',(SELECT COALESCE(sum(amount),0) FROM public.referral_rewards WHERE status='paid'),
  'today_registrations',(SELECT COALESCE(sum(registrations),0) FROM public.referral_stats WHERE date=(now() AT TIME ZONE 'Europe/Moscow')::date),
  'today_activations',(SELECT COALESCE(sum(activations),0) FROM public.referral_stats WHERE date=(now() AT TIME ZONE 'Europe/Moscow')::date),
  'today_earnings',(SELECT COALESCE(sum(earnings),0) FROM public.referral_stats WHERE date=(now() AT TIME ZONE 'Europe/Moscow')::date)) INTO v_result FROM public.referrals;
 RETURN v_result;
END $$;

-- ---------------------------------------------------------------------------
-- XP and achievements: one locked update, invariant total=sum(categories).
-- Direct XP mutation is service/admin only; trigger calls remain supported.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_add_xp(p_user_id uuid,p_amount numeric,p_category text DEFAULT 'forum',p_admin_override boolean DEFAULT false)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
 v_role text:=current_setting('request.jwt.claim.role',true); v_stats public.forum_user_stats%ROWTYPE;
 v_amount integer; v_cap integer; v_category text; v_tier public.reputation_tiers%ROWTYPE;
BEGIN
 IF p_amount IS NULL OR p_amount<>trunc(p_amount) OR abs(p_amount)>100000 THEN RAISE EXCEPTION 'invalid_xp_amount'; END IF;
 IF pg_trigger_depth()=0 AND v_role IS DISTINCT FROM 'service_role' AND (v_caller IS NULL OR NOT public.is_admin(v_caller)) THEN
   RAISE EXCEPTION 'xp_writer_required' USING ERRCODE='42501'; END IF;
 v_category:=CASE WHEN p_category IN('forum','music','social') THEN p_category ELSE 'social' END;
 INSERT INTO public.forum_user_stats(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO v_stats FROM public.forum_user_stats WHERE user_id=p_user_id FOR UPDATE;
 IF v_stats.xp_daily_date IS DISTINCT FROM current_date THEN v_stats.xp_daily_earned:=0; END IF;
 v_cap:=COALESCE((SELECT (value->>'xp_daily_cap')::integer FROM public.economy_config WHERE key='inflation_control'),150);
 v_amount:=p_amount::integer;
 IF v_amount>0 AND NOT p_admin_override THEN v_amount:=LEAST(v_amount,GREATEST(0,v_cap-v_stats.xp_daily_earned)); END IF;
 IF v_amount=0 THEN RETURN 0; END IF;
 UPDATE public.forum_user_stats SET
  xp_forum=CASE WHEN v_category='forum' THEN GREATEST(0,xp_forum+v_amount) ELSE xp_forum END,
  xp_music=CASE WHEN v_category='music' THEN GREATEST(0,xp_music+v_amount) ELSE xp_music END,
  xp_social=CASE WHEN v_category='social' THEN GREATEST(0,xp_social+v_amount) ELSE xp_social END,
  xp_daily_earned=CASE WHEN v_amount>0 AND NOT p_admin_override THEN v_stats.xp_daily_earned+v_amount ELSE v_stats.xp_daily_earned END,
  xp_daily_date=current_date,updated_at=now() WHERE user_id=p_user_id;
 UPDATE public.forum_user_stats SET xp_total=xp_forum+xp_music+xp_social WHERE user_id=p_user_id RETURNING * INTO v_stats;
 SELECT * INTO v_tier FROM public.reputation_tiers WHERE min_xp<=v_stats.xp_total ORDER BY level DESC LIMIT 1;
 IF FOUND THEN UPDATE public.forum_user_stats SET tier=v_tier.key,vote_weight=v_tier.vote_weight,trust_level=v_tier.level WHERE user_id=p_user_id; END IF;
 INSERT INTO public.reputation_events(user_id,event_type,xp_delta,category,source_type,metadata)
 VALUES(p_user_id,'xp_adjusted',v_amount,v_category,CASE WHEN p_admin_override THEN 'admin' ELSE 'system' END,jsonb_build_object('via','fn_add_xp'));
 RETURN v_amount;
END $$;

CREATE OR REPLACE FUNCTION public.check_user_achievements(p_user_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid; v_a record; v_s public.forum_user_stats%ROWTYPE;
 v_p public.profiles%ROWTYPE; v_value integer; v_new uuid; v_earned integer:=0; v_tier public.reputation_tiers%ROWTYPE;
BEGIN
 IF v_caller IS NULL OR (v_caller<>p_user_id AND NOT public.is_admin(v_caller)) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 INSERT INTO public.forum_user_stats(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO v_s FROM public.forum_user_stats WHERE user_id=p_user_id FOR UPDATE;
 SELECT * INTO v_p FROM public.profiles WHERE user_id=p_user_id FOR UPDATE;
 FOR v_a IN SELECT * FROM public.achievements WHERE is_active ORDER BY sort_order LOOP
  v_value:=CASE v_a.requirement_type WHEN 'xp_total' THEN v_s.xp_total WHEN 'xp_forum' THEN v_s.xp_forum WHEN 'xp_music' THEN v_s.xp_music
   WHEN 'xp_social' THEN v_s.xp_social WHEN 'reputation_score' THEN v_s.reputation_score WHEN 'followers_count' THEN v_p.followers_count
   WHEN 'contests_entered' THEN v_p.contests_entered WHEN 'contests_won' THEN v_p.contests_won WHEN 'streak_days' THEN v_s.streak_days
   WHEN 'posts_created' THEN v_s.posts_created WHEN 'topics_created' THEN v_s.topics_created WHEN 'solutions_count' THEN v_s.solutions_count ELSE 0 END;
  IF COALESCE(v_value,0)>=v_a.requirement_value THEN
   INSERT INTO public.user_achievements(user_id,achievement_id,earned_at) VALUES(p_user_id,v_a.id,now())
    ON CONFLICT(user_id,achievement_id) DO NOTHING RETURNING id INTO v_new;
   IF v_new IS NOT NULL THEN
    IF v_a.xp_reward>0 THEN UPDATE public.forum_user_stats SET xp_social=xp_social+v_a.xp_reward WHERE user_id=p_user_id; END IF;
    IF v_a.credit_reward>0 THEN UPDATE public.profiles SET credits=COALESCE(credits,0)+v_a.credit_reward WHERE user_id=p_user_id; END IF;
    INSERT INTO public.reputation_events(user_id,event_type,xp_delta,category,source_type,source_id,metadata)
     VALUES(p_user_id,'achievement_unlocked',v_a.xp_reward,'social','achievement',v_a.id,jsonb_build_object('achievement_key',v_a.key));
    INSERT INTO public.notifications(user_id,type,title,message,data) VALUES(p_user_id,'achievement','Достижение разблокировано!',v_a.icon||' '||v_a.name_ru,jsonb_build_object('achievement_key',v_a.key));
    v_earned:=v_earned+1; v_new:=NULL;
   END IF;
  END IF;
 END LOOP;
 UPDATE public.forum_user_stats SET xp_total=xp_forum+xp_music+xp_social,updated_at=now() WHERE user_id=p_user_id RETURNING * INTO v_s;
 SELECT * INTO v_tier FROM public.reputation_tiers WHERE min_xp<=v_s.xp_total ORDER BY level DESC LIMIT 1;
 IF FOUND THEN UPDATE public.forum_user_stats SET tier=v_tier.key,vote_weight=v_tier.vote_weight,trust_level=v_tier.level WHERE user_id=p_user_id; END IF;
 RETURN v_earned;
END $$;

-- Public, non-sensitive runtime progression config (removes UI hardcodes).
CREATE OR REPLACE FUNCTION public.get_public_progression_config()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER STABLE SET search_path=public AS $$
 SELECT jsonb_build_object('xp_daily_cap',COALESCE((SELECT (value->>'xp_daily_cap')::integer FROM public.economy_config WHERE key='inflation_control'),150),
  'tiers',COALESCE((SELECT jsonb_agg(jsonb_build_object('key',key,'level',level,'min_xp',min_xp,'name_ru',name_ru,'icon',icon) ORDER BY level) FROM public.reputation_tiers),'[]'::jsonb))
$$;

-- Credit mutations are never a public utility. The API additionally enforces
-- this boundary, but the database function must remain safe on direct calls.
CREATE OR REPLACE FUNCTION public.add_user_credits(p_user_id uuid,p_amount integer,p_reason text DEFAULT 'Начисление')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
 v_role text:=current_setting('request.jwt.claim.role',true); v_new_balance integer;
BEGIN
 IF v_role IS DISTINCT FROM 'service_role' AND (v_caller IS NULL OR NOT public.is_admin(v_caller)) THEN
  RAISE EXCEPTION 'Unauthorized';
 END IF;
 IF p_amount IS NULL OR p_amount<=0 OR p_amount>1000000 THEN
  RETURN jsonb_build_object('ok',false,'error','amount_out_of_range');
 END IF;
 UPDATE public.profiles SET balance=COALESCE(balance,0)+p_amount WHERE user_id=p_user_id
  RETURNING balance INTO v_new_balance;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','user_not_found'); END IF;
 INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type)
 VALUES(p_user_id,p_amount,'credit_reward',left(COALESCE(p_reason,'Начисление'),500),'system');
 RETURN jsonb_build_object('ok',true,'new_balance',v_new_balance);
END $$;

-- Protect economy reporting/calculation functions even if their old bodies remain.
CREATE OR REPLACE FUNCTION public.get_creator_earnings_profile(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid; v_e public.creator_earnings%ROWTYPE;
 v_t record; v_quality numeric; v_recent jsonb;
BEGIN
 IF v_caller IS NULL OR (v_caller<>p_user_id AND NOT public.is_admin(v_caller)) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 INSERT INTO public.creator_earnings(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO v_e FROM public.creator_earnings WHERE user_id=p_user_id;
 SELECT fus.tier,fus.xp_total,rt.name_ru,rt.marketplace_commission,rt.attribution_multiplier,
  rt.bonus_generations,rt.feed_boost,rt.can_sell_premium,rt.can_create_voice_print INTO v_t
 FROM public.forum_user_stats fus LEFT JOIN public.reputation_tiers rt ON rt.key=fus.tier WHERE fus.user_id=p_user_id;
 SELECT COALESCE(avg(quality_score),0) INTO v_quality FROM public.track_quality_scores
  WHERE user_id=p_user_id AND metrics_collected_at>now()-interval '30 days';
 SELECT COALESCE(jsonb_agg(x ORDER BY x->>'period_start' DESC),'[]'::jsonb) INTO v_recent FROM (
  SELECT jsonb_build_object('period_start',ap.period_start,'engagement_score',s.engagement_score,
   'earned_amount',s.earned_amount,'pool_share_percent',s.pool_share_percent) x
  FROM public.attribution_shares s JOIN public.attribution_pools ap ON ap.id=s.pool_id
  WHERE s.user_id=p_user_id ORDER BY ap.period_start DESC LIMIT 6) q;
 RETURN jsonb_build_object('earnings',jsonb_build_object('total_earned',v_e.total_earned,
  'total_attribution',v_e.total_attribution,'total_marketplace',v_e.total_marketplace_sales,
  'total_premium',v_e.total_premium_content,'total_tips',v_e.total_tips,'total_royalties',v_e.total_royalties,
  'current_month',v_e.current_month_total,'pending_payout',v_e.pending_payout),
  'tier',jsonb_build_object('key',COALESCE(v_t.tier,'newcomer'),'name',COALESCE(v_t.name_ru,'Новичок'),
   'xp',COALESCE(v_t.xp_total,0),'commission',COALESCE(v_t.marketplace_commission,0.15),
   'attribution_multiplier',COALESCE(v_t.attribution_multiplier,0),'bonus_generations',COALESCE(v_t.bonus_generations,0),
   'feed_boost',COALESCE(v_t.feed_boost,1),'can_sell_premium',COALESCE(v_t.can_sell_premium,false),
   'can_create_voice_print',COALESCE(v_t.can_create_voice_print,false)),
  'quality_avg',v_quality,'recent_attribution',v_recent,'progression',public.get_public_progression_config());
END $$;

-- Wrap legacy implementations so owner-connected gateways cannot bypass checks.
DO $$ BEGIN
 IF to_regprocedure('public.award_xp_internal_legacy(uuid,text,text,uuid,jsonb)') IS NULL THEN
  ALTER FUNCTION public.award_xp(uuid,text,text,uuid,jsonb) RENAME TO award_xp_internal_legacy;
 END IF;
 IF to_regprocedure('public.get_economy_health_internal_legacy()') IS NULL THEN
  ALTER FUNCTION public.get_economy_health() RENAME TO get_economy_health_internal_legacy;
 END IF;
 IF to_regprocedure('public.calculate_track_quality_internal_legacy(uuid)') IS NULL THEN
  ALTER FUNCTION public.calculate_track_quality(uuid) RENAME TO calculate_track_quality_internal_legacy;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.award_xp(p_user_id uuid,p_event_type text,p_source_type text DEFAULT NULL,
 p_source_id uuid DEFAULT NULL,p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
 v_role text:=current_setting('request.jwt.claim.role',true);
BEGIN
 IF pg_trigger_depth()=0 AND v_role IS DISTINCT FROM 'service_role' AND (v_caller IS NULL OR NOT public.is_admin(v_caller)) THEN
  RAISE EXCEPTION 'xp_writer_required' USING ERRCODE='42501'; END IF;
 RETURN public.award_xp_internal_legacy(p_user_id,p_event_type,p_source_type,p_source_id,p_metadata);
END $$;

CREATE OR REPLACE FUNCTION public.get_economy_health()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
BEGIN
 IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN RAISE EXCEPTION 'admin_required' USING ERRCODE='42501'; END IF;
 RETURN public.get_economy_health_internal_legacy();
END $$;

CREATE OR REPLACE FUNCTION public.calculate_track_quality(p_track_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_caller uuid:=nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
 v_role text:=current_setting('request.jwt.claim.role',true); v_owner uuid;
BEGIN
 SELECT user_id INTO v_owner FROM public.tracks WHERE id=p_track_id;
 IF v_owner IS NULL THEN RETURN jsonb_build_object('error','track_not_found'); END IF;
 IF v_role IS DISTINCT FROM 'service_role' AND (v_caller IS NULL OR (v_caller<>v_owner AND NOT public.is_admin(v_caller))) THEN
  RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 RETURN public.calculate_track_quality_internal_legacy(p_track_id);
END $$;

-- RLS expresses the canonical access model (the API must use a non-owner role).
ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_payment_evidence ENABLE ROW LEVEL SECURITY;
DO $$ DECLARE t text; BEGIN
 FOR t IN SELECT unnest(ARRAY['referral_codes','referrals','referral_rewards','referral_stats','referral_settings','referral_payment_evidence']) LOOP
  EXECUTE format('DROP POLICY IF EXISTS economy_canonical_access ON public.%I',t);
 END LOOP;
END $$;
CREATE POLICY economy_canonical_access ON public.referral_codes FOR ALL USING(user_id=auth.uid() OR public.is_admin(auth.uid())) WITH CHECK(user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY economy_canonical_access ON public.referrals FOR SELECT USING(referrer_id=auth.uid() OR referee_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY economy_canonical_access ON public.referral_rewards FOR SELECT USING(user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY economy_canonical_access ON public.referral_stats FOR SELECT USING(user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY economy_canonical_access ON public.referral_settings FOR SELECT USING(auth.uid() IS NOT NULL);
CREATE POLICY economy_canonical_access ON public.referral_payment_evidence FOR ALL USING(current_setting('request.jwt.claim.role',true)='service_role') WITH CHECK(current_setting('request.jwt.claim.role',true)='service_role');

-- Exact execution grants. Clear inherited and explicit grants before rebuilding
-- the least-privilege matrix (REVOKE FROM PUBLIC alone is not sufficient).
REVOKE EXECUTE ON FUNCTION public.get_or_create_referral_code(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.update_referral_settings(jsonb) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.register_referral(uuid,text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.activate_referral(uuid,numeric) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.activate_referral(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.process_referral_deposit_bonus(uuid,numeric) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.process_referral_deposit_bonus(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.get_my_referral_stats() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.get_referral_overview() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_add_xp(uuid,numeric,text,boolean) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.award_xp(uuid,text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.safe_award_xp(uuid,text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.check_user_achievements(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.get_creator_earnings_profile(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.get_economy_health() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_track_quality(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.add_user_credits(uuid,integer,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.radio_award_listen_xp(uuid,uuid,integer,integer,text,text,text,boolean) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.radio_award_listen_xp(uuid,uuid,integer,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_or_create_referral_code(uuid),public.register_referral(uuid,text,text,text,text),
 public.get_my_referral_stats(),public.check_user_achievements(uuid),public.get_creator_earnings_profile(uuid),public.get_public_progression_config() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_progression_config() TO anon;
GRANT EXECUTE ON FUNCTION public.update_referral_settings(jsonb),public.get_referral_overview(),public.get_economy_health(),
 public.calculate_track_quality(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.radio_award_listen_xp(uuid,uuid,integer,integer,text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.activate_referral(uuid,uuid),public.process_referral_deposit_bonus(uuid,uuid),
 public.fn_add_xp(uuid,numeric,text,boolean),public.award_xp(uuid,text,text,uuid,jsonb),
 public.safe_award_xp(uuid,text,text,uuid,jsonb),public.add_user_credits(uuid,integer,text) TO service_role;

COMMIT;
