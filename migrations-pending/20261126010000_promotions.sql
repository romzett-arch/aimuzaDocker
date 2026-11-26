CREATE SCHEMA promotions;
REVOKE ALL ON SCHEMA promotions FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE promotions.campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 100),
  rewards jsonb NOT NULL,
  image_resolution text NOT NULL CHECK (image_resolution IN ('1K','2K','3000x3000')),
  starts_at timestamptz NOT NULL,
  redeem_until timestamptz NOT NULL CHECK (redeem_until > starts_at),
  valid_days integer NOT NULL CHECK (valid_days BETWEEN 1 AND 365),
  activation_limit integer NOT NULL CHECK (activation_limit BETWEEN 1 AND 100000),
  activations integer NOT NULL DEFAULT 0 CHECK (activations <= activation_limit),
  active boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE promotions.codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES promotions.campaigns,
  digest text NOT NULL UNIQUE,
  hint text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('public','single','personal')),
  target_user_id uuid,
  activation_limit integer NOT NULL,
  activations integer NOT NULL DEFAULT 0 CHECK (activations <= activation_limit),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON promotions.codes (campaign_id);
CREATE TABLE promotions.activations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES promotions.campaigns,
  code_id uuid NOT NULL REFERENCES promotions.codes,
  user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  rewards jsonb NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id,user_id)
);
CREATE TABLE promotions.grants (
  activation_id uuid NOT NULL REFERENCES promotions.activations ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('music','image','deposit','release','upload')),
  total integer NOT NULL CHECK (total > 0),
  remaining integer NOT NULL CHECK (remaining BETWEEN 0 AND total),
  PRIMARY KEY (activation_id,kind)
);
CREATE TABLE promotions.uses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activation_id uuid NOT NULL,
  kind text NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved','used','returned')),
  created_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  FOREIGN KEY (activation_id,kind) REFERENCES promotions.grants ON DELETE CASCADE
);
CREATE UNIQUE INDEX ON promotions.uses (user_id,kind,operation_id) WHERE status <> 'returned';
CREATE INDEX ON promotions.uses (activation_id,kind);
CREATE TABLE promotions.attempts (
  user_id uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  window_started timestamptz NOT NULL,
  attempts integer NOT NULL
);
CREATE TABLE promotions.admin_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES promotions.campaigns,
  actor uuid NOT NULL,
  action text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION promotions.require_admin()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL OR NOT (public.has_role(actor,'admin') OR public.has_role(actor,'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  RETURN actor;
END $$;

CREATE FUNCTION public.admin_create_promo_campaign(p_config jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  actor uuid := promotions.require_admin();
  reward record;
  new_campaign uuid;
BEGIN
  IF jsonb_typeof(p_config->'rewards') IS DISTINCT FROM 'object' OR p_config->'rewards' = '{}' THEN
    RAISE EXCEPTION 'Укажите хотя бы один бонус';
  END IF;
  FOR reward IN SELECT * FROM jsonb_each_text(p_config->'rewards') LOOP
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
    (title,rewards,image_resolution,starts_at,redeem_until,valid_days,activation_limit,created_by)
  VALUES
    (btrim(p_config->>'title'),p_config->'rewards',COALESCE(p_config->>'image_resolution','1K'),
     (p_config->>'starts_at')::timestamptz,(p_config->>'redeem_until')::timestamptz,
     (p_config->>'valid_days')::integer,(p_config->>'activation_limit')::integer,actor)
  RETURNING id INTO new_campaign;
  INSERT INTO promotions.admin_events(campaign_id,actor,action) VALUES (new_campaign,actor,'created');
  RETURN new_campaign;
END $$;

CREATE FUNCTION public.admin_issue_promo_codes(p_campaign_id uuid, p_config jsonb)
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
    new_code := COALESCE(custom_code,'AIM-' || upper(encode(public.gen_random_bytes(10),'hex')));
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

CREATE FUNCTION public.admin_set_promo_status(p_campaign_id uuid, p_active boolean, p_code_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := promotions.require_admin();
BEGIN
  PERFORM FROM promotions.campaigns WHERE id=p_campaign_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Кампания недоступна'; END IF;
  IF p_code_id IS NULL THEN
    UPDATE promotions.campaigns SET active=p_active WHERE id=p_campaign_id;
  ELSE
    UPDATE promotions.codes SET active=p_active WHERE id=p_code_id AND campaign_id=p_campaign_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Код недоступен'; END IF;
  END IF;
  INSERT INTO promotions.admin_events(campaign_id,actor,action,detail)
  VALUES (p_campaign_id,actor,'status_changed',jsonb_build_object('active',p_active,'code_id',p_code_id));
END $$;

CREATE FUNCTION public.admin_list_promo_campaigns(p_campaign_id uuid DEFAULT NULL, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  PERFORM promotions.require_admin();
  IF p_campaign_id IS NOT NULL THEN
    RETURN COALESCE((SELECT jsonb_agg(to_jsonb(c) - 'digest' ORDER BY c.created_at DESC,c.id)
      FROM (SELECT * FROM promotions.codes WHERE campaign_id=p_campaign_id
            ORDER BY created_at DESC,id LIMIT 50 OFFSET greatest(p_offset,0)) c),'[]');
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(c) || jsonb_build_object(
    'used',COALESCE((SELECT jsonb_object_agg(s.kind,s.quantity) FROM (
      SELECT u.kind,count(*) AS quantity FROM promotions.uses u
      JOIN promotions.activations a ON a.id=u.activation_id
      WHERE a.campaign_id=c.id AND u.status='used' GROUP BY u.kind) s),'{}'),
    'available',COALESCE((SELECT jsonb_object_agg(s.kind,s.quantity) FROM (
      SELECT g.kind,sum(g.remaining) AS quantity FROM promotions.grants g
      JOIN promotions.activations a ON a.id=g.activation_id
      WHERE a.campaign_id=c.id AND a.expires_at>now() GROUP BY g.kind) s),'{}')
  ) ORDER BY c.created_at DESC,c.id)
  FROM (SELECT * FROM promotions.campaigns ORDER BY created_at DESC,id
        LIMIT 50 OFFSET greatest(p_offset,0)) c),'[]');
END $$;

CREATE FUNCTION public.use_promo_code(p_code text, p_activate boolean DEFAULT false)
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

CREATE FUNCTION public.get_my_promo_bonuses()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',a.id,'title',c.title,'expires_at',a.expires_at,'image_resolution',c.image_resolution,
    'balance_amount',COALESCE((a.rewards->>'balance')::integer,0),
    'bonuses',COALESCE((SELECT jsonb_object_agg(g.kind,jsonb_build_object('total',g.total,
      'remaining',CASE WHEN a.expires_at>now() THEN g.remaining ELSE 0 END))
      FROM promotions.grants g WHERE g.activation_id=a.id),'{}')
  ) ORDER BY a.created_at DESC),'[]')
  FROM (SELECT * FROM promotions.activations WHERE user_id=auth.uid() ORDER BY created_at DESC LIMIT 100) a
  JOIN promotions.campaigns c ON c.id=a.campaign_id;
$$;

CREATE FUNCTION promotions.reserve(p_user uuid,p_kind text,p_operation uuid,p_resolution text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE source_id uuid;
BEGIN
  IF p_operation IS NULL THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('promo:' || p_user || ':' || p_kind,0));
  IF EXISTS (SELECT 1 FROM promotions.uses WHERE user_id=p_user AND kind=p_kind
             AND operation_id=p_operation AND status IN ('reserved','used')) THEN RETURN true; END IF;
  SELECT g.activation_id INTO source_id
  FROM promotions.grants g JOIN promotions.activations a ON a.id=g.activation_id
  JOIN promotions.campaigns c ON c.id=a.campaign_id
  WHERE a.user_id=p_user AND g.kind=p_kind AND g.remaining>0 AND a.expires_at>now()
    AND (p_kind<>'image' OR c.image_resolution=p_resolution)
  ORDER BY a.expires_at,a.created_at,a.id LIMIT 1 FOR UPDATE OF g;
  IF NOT FOUND THEN RETURN false; END IF;
  UPDATE promotions.grants SET remaining=remaining-1 WHERE activation_id=source_id AND kind=p_kind;
  INSERT INTO promotions.uses(activation_id,kind,user_id,operation_id)
  VALUES (source_id,p_kind,p_user,p_operation);
  RETURN true;
END $$;

CREATE FUNCTION promotions.settle(p_user uuid,p_kind text,p_operation uuid,p_success boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE source_id uuid;
BEGIN
  UPDATE promotions.uses SET status=CASE WHEN p_success THEN 'used' ELSE 'returned' END,closed_at=now()
  WHERE user_id=p_user AND kind=p_kind AND operation_id=p_operation AND status='reserved'
  RETURNING activation_id INTO source_id;
  IF FOUND AND NOT p_success THEN
    UPDATE promotions.grants SET remaining=remaining+1 WHERE activation_id=source_id AND kind=p_kind;
  END IF;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA promotions FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_create_promo_campaign(jsonb),public.admin_issue_promo_codes(uuid,jsonb),
  public.admin_set_promo_status(uuid,boolean,uuid),public.admin_list_promo_campaigns(uuid,integer),
  public.use_promo_code(text,boolean),public.get_my_promo_bonuses() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_promo_campaign(jsonb),public.admin_issue_promo_codes(uuid,jsonb),
  public.admin_set_promo_status(uuid,boolean,uuid),public.admin_list_promo_campaigns(uuid,integer),
  public.use_promo_code(text,boolean),public.get_my_promo_bonuses() TO authenticated;

