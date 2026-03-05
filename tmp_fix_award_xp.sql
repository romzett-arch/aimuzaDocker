-- Исправляем award_xp: маппинг contest/general → xp_social
-- (contest = социальная активность, general = общая вовлечённость)

-- Получаем текущую сигнатуру
DO $$
DECLARE
  v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc
  WHERE proname = 'award_xp' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
  
  IF v_src IS NULL THEN
    RAISE NOTICE 'award_xp not found, skipping';
    RETURN;
  END IF;

  -- Заменяем маппинг категорий
  v_src := replace(v_src, 
    E'xp_social = CASE WHEN v_config.category = ''social'' THEN COALESCE(xp_social, 0) + v_xp ELSE COALESCE(xp_social, 0) END',
    E'xp_social = CASE WHEN v_config.category IN (''social'', ''contest'', ''general'') THEN COALESCE(xp_social, 0) + v_xp ELSE COALESCE(xp_social, 0) END'
  );
  
  RAISE NOTICE 'Updated award_xp category mapping';
END $$;
