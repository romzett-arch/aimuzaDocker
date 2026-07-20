-- A campaign may be activated only when it can actually produce a delivery.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_ad_campaign_readiness(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign public.ad_campaigns%ROWTYPE;
  v_issues TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Доступно только администратору' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_campaign FROM public.ad_campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рекламная кампания не найдена' USING ERRCODE = 'P0002';
  END IF;

  IF length(btrim(COALESCE(v_campaign.name, ''))) < 2 THEN
    v_issues := array_append(v_issues, 'Укажите понятное название кампании');
  END IF;
  IF v_campaign.end_date IS NOT NULL AND v_campaign.start_date IS NOT NULL
     AND v_campaign.end_date <= v_campaign.start_date THEN
    v_issues := array_append(v_issues, 'Дата окончания должна быть позже даты начала');
  END IF;
  IF v_campaign.end_date IS NOT NULL AND v_campaign.end_date <= now() THEN
    v_issues := array_append(v_issues, 'Дата окончания уже прошла');
  END IF;
  IF COALESCE(v_campaign.budget_total, 1) = 0 THEN
    v_issues := array_append(v_issues, 'Общий лимит показов равен нулю');
  END IF;
  IF COALESCE(v_campaign.budget_daily, 1) = 0 THEN
    v_issues := array_append(v_issues, 'Дневной лимит показов равен нулю');
  END IF;
  IF v_campaign.budget_total IS NOT NULL AND v_campaign.budget_daily IS NOT NULL
     AND v_campaign.budget_daily > v_campaign.budget_total THEN
    v_issues := array_append(v_issues, 'Дневной лимит не может быть больше общего');
  END IF;

  IF v_campaign.campaign_type = 'external'
     AND length(btrim(COALESCE(v_campaign.advertiser_name, ''))) < 2 THEN
    v_issues := array_append(v_issues, 'Укажите название рекламодателя');
  END IF;
  IF v_campaign.campaign_type = 'internal' THEN
    IF v_campaign.internal_type IS NULL OR v_campaign.internal_id IS NULL THEN
      v_issues := array_append(v_issues, 'Выберите объект платформы для внутреннего продвижения');
    ELSIF v_campaign.internal_type = 'track'
      AND NOT EXISTS (SELECT 1 FROM public.tracks WHERE id = v_campaign.internal_id) THEN
      v_issues := array_append(v_issues, 'Выбранный трек не найден');
    ELSIF v_campaign.internal_type = 'contest'
      AND NOT EXISTS (SELECT 1 FROM public.contests WHERE id = v_campaign.internal_id) THEN
      v_issues := array_append(v_issues, 'Выбранный конкурс не найден');
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.ad_campaign_slots cs
    JOIN public.ad_slots s ON s.id = cs.slot_id
    WHERE cs.campaign_id = p_campaign_id
      AND COALESCE(cs.is_active, true)
      AND COALESCE(s.is_enabled, s.is_active, true)
  ) THEN
    v_issues := array_append(v_issues, 'Выберите хотя бы одно место показа');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.ad_creatives cr
    WHERE cr.campaign_id = p_campaign_id
      AND COALESCE(cr.is_active, true)
      AND (cr.media_url IS NOT NULL OR cr.external_video_url IS NOT NULL
        OR length(btrim(COALESCE(cr.title, ''))) > 0)
  ) THEN
    v_issues := array_append(v_issues, 'Добавьте хотя бы одно готовое объявление');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.ad_campaign_slots cs
    JOIN public.ad_slots s ON s.id = cs.slot_id
    WHERE cs.campaign_id = p_campaign_id
      AND COALESCE(cs.is_active, true)
      AND COALESCE(s.is_enabled, s.is_active, true)
      AND NOT EXISTS (
        SELECT 1 FROM public.ad_creatives cr
        WHERE cr.campaign_id = p_campaign_id
          AND COALESCE(cr.is_active, true)
          AND (cr.media_url IS NOT NULL OR cr.external_video_url IS NOT NULL
            OR length(btrim(COALESCE(cr.title, ''))) > 0)
          AND (s.supported_types IS NULL OR cardinality(s.supported_types) = 0
            OR COALESCE(cr.creative_type, cr.type, 'image') = ANY(s.supported_types))
      )
  ) THEN
    v_issues := array_append(v_issues, 'Для одного из мест показа нет подходящего объявления');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ad_targeting t
    WHERE t.campaign_id = p_campaign_id
      AND NOT COALESCE(t.target_free_users, false)
      AND NOT COALESCE(t.target_subscribed_users, false)
  ) THEN
    v_issues := array_append(v_issues, 'В аудитории выключены все группы пользователей');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.ad_targeting t
    WHERE t.campaign_id = p_campaign_id
      AND NOT COALESCE(t.target_mobile, false)
      AND NOT COALESCE(t.target_desktop, false)
  ) THEN
    v_issues := array_append(v_issues, 'Выключены показы и на телефонах, и на компьютерах');
  END IF;

  RETURN jsonb_build_object(
    'ready', cardinality(v_issues) = 0,
    'issues', to_jsonb(v_issues)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_ad_campaign_status(
  p_campaign_id UUID,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_readiness JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Доступно только администратору' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('draft', 'active', 'paused', 'completed', 'archived') THEN
    RAISE EXCEPTION 'Неизвестный статус кампании' USING ERRCODE = '22023';
  END IF;

  IF p_status = 'active' THEN
    v_readiness := public.get_ad_campaign_readiness(p_campaign_id);
    IF NOT COALESCE((v_readiness->>'ready')::boolean, false) THEN
      RAISE EXCEPTION 'Кампания не готова: %', array_to_string(
        ARRAY(SELECT jsonb_array_elements_text(v_readiness->'issues')), '; '
      ) USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.ad_campaigns
  SET status = p_status, updated_at = now()
  WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рекламная кампания не найдена' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('status', p_status, 'readiness', v_readiness);
END;
$$;

REVOKE ALL ON FUNCTION public.get_ad_campaign_readiness(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_ad_campaign_status(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_ad_campaign_readiness(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_ad_campaign_status(UUID, TEXT) TO authenticated;

COMMIT;
