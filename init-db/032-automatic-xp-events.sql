-- ═══════════════════════════════════════════════════════════════
-- 032-automatic-xp-events.sql
-- Добавляет недостающие события XP и safe_award_xp для радио и др.
-- fix-rewards-audit.sql не в init-db, поэтому радио/прогнозы не начисляли XP.
-- ═══════════════════════════════════════════════════════════════

-- 1. Добавить недостающие события в xp_event_config
INSERT INTO public.xp_event_config (event_type, xp_amount, reputation_amount, category, cooldown_minutes, daily_limit, requires_quality_check, description)
VALUES
  -- Радио
  ('radio_listen',          1, 0, 'music',   0, 50, false, 'Прослушивание трека на радио'),
  ('prediction_correct',   10, 3, 'general', 0, 20, false, 'Верный прогноз на радио'),
  ('prediction_wrong',      1, 0, 'general', 0, 50, false, 'Неверный прогноз на радио (утешительный)'),
  -- QA баунти (используется в useAdminWorkflows)
  ('qa_bounty_resolved',   50, 15, 'general', 0, 5,  false, 'Закрытие баунти за найденную ошибку'),
  -- Модерация
  ('track_rejected',        0, -5, 'music',  0, 0,  false, 'Трек отклонён модерацией (штраф)')
ON CONFLICT (event_type) DO UPDATE SET
  xp_amount = EXCLUDED.xp_amount,
  reputation_amount = EXCLUDED.reputation_amount,
  category = EXCLUDED.category,
  cooldown_minutes = EXCLUDED.cooldown_minutes,
  daily_limit = EXCLUDED.daily_limit,
  description = EXCLUDED.description;


-- 2. Создать safe_award_xp — обёртка для award_xp (используется в радио)
-- Радио вызывает safe_award_xp из radio_award_listen_xp и radio_resolve_predictions
CREATE OR REPLACE FUNCTION public.safe_award_xp(
  p_user_id UUID,
  p_event_type TEXT,
  p_source_type TEXT DEFAULT NULL,
  p_source_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  PERFORM public.award_xp(p_user_id, p_event_type, p_source_type, p_source_id, p_metadata);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'safe_award_xp(%, %) failed: %', p_user_id, p_event_type, SQLERRM;
END;
$$;
