-- fn_add_xp: полная версия с admin_override и нормализацией категорий
-- Fixes:
--   1. Админ-начисления обходят дневной лимит (p_admin_override)
--   2. Категория 'general' нормализуется в 'forum' (чтобы xp_total = sum(categories))
--   3. Админ-начисления не засчитываются в xp_daily_earned
--   4. Логирование с source_type='admin' при override

DROP FUNCTION IF EXISTS public.fn_add_xp(UUID, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION public.fn_add_xp(
  p_user_id UUID,
  p_amount NUMERIC,
  p_category TEXT DEFAULT 'forum',
  p_admin_override BOOLEAN DEFAULT false
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_daily_cap INTEGER := 100;
  v_current_daily INTEGER;
  v_actual_amount INTEGER;
  v_new_total INTEGER;
  v_tier RECORD;
  v_event_type TEXT;
  v_effective_category TEXT;
BEGIN
  v_effective_category := CASE
    WHEN p_category IN ('forum', 'music', 'social') THEN p_category
    ELSE 'forum'
  END;

  INSERT INTO forum_user_stats (user_id)
    VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;

  UPDATE forum_user_stats
    SET xp_daily_earned = 0, xp_daily_date = CURRENT_DATE
    WHERE user_id = p_user_id
      AND (xp_daily_date IS NULL OR xp_daily_date < CURRENT_DATE);

  SELECT COALESCE(xp_daily_earned, 0) INTO v_current_daily
    FROM forum_user_stats WHERE user_id = p_user_id;

  IF p_amount > 0 THEN
    IF p_admin_override THEN
      v_actual_amount := p_amount::integer;
    ELSE
      v_actual_amount := LEAST(p_amount::integer, v_daily_cap - v_current_daily);
      IF v_actual_amount <= 0 THEN RETURN 0; END IF;
    END IF;
  ELSE
    v_actual_amount := p_amount::integer;
  END IF;

  UPDATE forum_user_stats SET
    xp_total = GREATEST(0, xp_total + v_actual_amount),
    xp_daily_earned = CASE WHEN v_actual_amount > 0 AND NOT p_admin_override
      THEN xp_daily_earned + v_actual_amount ELSE xp_daily_earned END,
    xp_forum = CASE WHEN v_effective_category = 'forum'
      THEN GREATEST(0, xp_forum + v_actual_amount) ELSE xp_forum END,
    xp_music = CASE WHEN v_effective_category = 'music'
      THEN GREATEST(0, xp_music + v_actual_amount) ELSE xp_music END,
    xp_social = CASE WHEN v_effective_category = 'social'
      THEN GREATEST(0, xp_social + v_actual_amount) ELSE xp_social END,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_total;

  SELECT * INTO v_tier FROM public.reputation_tiers
    WHERE min_xp <= COALESCE(v_new_total, 0)
    ORDER BY level DESC LIMIT 1;

  IF v_tier IS NOT NULL THEN
    UPDATE forum_user_stats SET
      tier = v_tier.key,
      vote_weight = v_tier.vote_weight,
      trust_level = v_tier.level
    WHERE user_id = p_user_id;
  END IF;

  v_event_type := CASE v_effective_category
    WHEN 'forum' THEN 'forum_xp'
    WHEN 'music' THEN 'music_xp'
    WHEN 'social' THEN 'social_xp'
    ELSE 'general_xp'
  END;

  IF v_actual_amount <> 0 THEN
    INSERT INTO public.reputation_events
      (user_id, event_type, xp_delta, reputation_delta, category, source_type, metadata)
    VALUES
      (p_user_id, v_event_type, v_actual_amount, 0, v_effective_category,
       CASE WHEN p_admin_override THEN 'admin' ELSE 'trigger' END,
       jsonb_build_object('via', 'fn_add_xp', 'admin_override', p_admin_override));
  END IF;

  RETURN COALESCE(v_actual_amount, 0);
END;
$$;

-- award_xp: маппинг contest/general → xp_social
-- (contest = социальная активность, general = общая вовлечённость)
DO $do$
DECLARE
  v_full_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_full_def
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE p.proname = 'award_xp' AND n.nspname = 'public';

  IF v_full_def IS NULL THEN RETURN; END IF;

  IF position('v_config.category IN (''social'', ''contest'', ''general'')' IN v_full_def) = 0 THEN
    v_full_def := replace(v_full_def,
      'v_config.category = ''social''',
      'v_config.category IN (''social'', ''contest'', ''general'')'
    );
  END IF;

  EXECUTE v_full_def;
END $do$;

-- resolve_qa_ticket: добавить xp_social + category 'social'
DO $do$
DECLARE
  v_full_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_full_def
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE p.proname = 'resolve_qa_ticket' AND n.nspname = 'public';

  IF v_full_def IS NULL THEN RETURN; END IF;

  IF position('xp_social = COALESCE(forum_user_stats.xp_social, 0) + v_final_xp' IN v_full_def) = 0 THEN
    v_full_def := replace(v_full_def,
      'xp_total = COALESCE(forum_user_stats.xp_total, 0) + v_final_xp,',
      'xp_total = COALESCE(forum_user_stats.xp_total, 0) + v_final_xp,' || chr(10) ||
      '         xp_social = COALESCE(forum_user_stats.xp_social, 0) + v_final_xp,'
    );
  END IF;

  IF position('''qa_report_resolved'', v_final_xp, v_rep, ''social''' IN v_full_def) = 0 THEN
    v_full_def := replace(v_full_def,
      '''qa_report_resolved'', v_final_xp, v_rep, ''general''',
      '''qa_report_resolved'', v_final_xp, v_rep, ''social'''
    );
  END IF;

  EXECUTE v_full_def;
END $do$;

-- Фикс консистентности: перенос неучтённого XP в xp_social
UPDATE forum_user_stats
SET xp_social = xp_social + (xp_total - (xp_forum + xp_music + xp_social))
WHERE xp_total > (xp_forum + xp_music + xp_social);
