ALTER TABLE promotions.campaigns
  ADD COLUMN deleted_at timestamptz,
  ADD CONSTRAINT promo_deleted_campaign_is_inactive CHECK (deleted_at IS NULL OR NOT active);

CREATE FUNCTION public.admin_delete_promo_campaign(p_campaign_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := promotions.require_admin();
BEGIN
  UPDATE promotions.campaigns SET active=false,deleted_at=now()
  WHERE id=p_campaign_id AND deleted_at IS NULL;

  IF FOUND THEN
    INSERT INTO promotions.admin_events(campaign_id,actor,action)
    VALUES (p_campaign_id,actor,'deleted');
  ELSIF NOT EXISTS (SELECT 1 FROM promotions.campaigns WHERE id=p_campaign_id) THEN
    RAISE EXCEPTION 'Кампания недоступна';
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_delete_promo_campaign(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_promo_campaign(uuid) TO authenticated;

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
  SELECT * INTO campaign FROM promotions.campaigns WHERE id = p_campaign_id AND deleted_at IS NULL FOR UPDATE;
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

CREATE OR REPLACE FUNCTION public.admin_set_promo_status(p_campaign_id uuid, p_active boolean, p_code_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := promotions.require_admin();
BEGIN
  PERFORM FROM promotions.campaigns WHERE id=p_campaign_id AND deleted_at IS NULL FOR UPDATE;
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

CREATE OR REPLACE FUNCTION public.admin_list_promo_campaigns(p_campaign_id uuid DEFAULT NULL, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  PERFORM promotions.require_admin();
  IF p_campaign_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM promotions.campaigns WHERE id=p_campaign_id AND deleted_at IS NULL) THEN
      RETURN '[]'::jsonb;
    END IF;
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
  FROM (SELECT * FROM promotions.campaigns WHERE deleted_at IS NULL ORDER BY created_at DESC,id
        LIMIT 50 OFFSET greatest(p_offset,0)) c),'[]');
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_promo_topup_percent(p_campaign_id uuid,p_percent integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE actor uuid := promotions.require_admin();
BEGIN
  IF p_percent IS NULL OR p_percent NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'Укажите процент от 0 до 100';
  END IF;
  UPDATE promotions.campaigns SET topup_percent=p_percent WHERE id=p_campaign_id AND deleted_at IS NULL AND topup_percent IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Кампания пополнения не найдена'; END IF;
  INSERT INTO promotions.admin_events(campaign_id,actor,action,detail)
  VALUES (p_campaign_id,actor,'topup_percent_changed',jsonb_build_object('percent',p_percent));
END $$;
