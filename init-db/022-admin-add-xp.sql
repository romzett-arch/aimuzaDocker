-- =====================================================
-- 022-admin-add-xp.sql
-- RPC admin_add_xp: ручное начисление XP пользователю (только super_admin)
-- =====================================================

CREATE OR REPLACE FUNCTION public.admin_add_xp(
  p_user_id UUID,
  p_xp_amount INTEGER,
  p_reason TEXT DEFAULT 'Ручное начисление администратором',
  p_reputation_amount INTEGER DEFAULT NULL  -- NULL = auto (xp/2, max 10)
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_admin_id UUID;
  v_rep INTEGER;
  v_new_xp INTEGER;
  v_new_rep INTEGER;
BEGIN
  v_admin_id := auth.uid();
  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Not authenticated');
  END IF;

  IF NOT public.is_super_admin(v_admin_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Только супер-администратор может начислять XP вручную');
  END IF;

  IF p_xp_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Сумма XP должна быть положительной');
  END IF;

  v_rep := COALESCE(p_reputation_amount, LEAST(p_xp_amount / 2, 10));
  IF v_rep < 0 THEN v_rep := 0; END IF;

  -- Ensure user stats exist
  INSERT INTO public.forum_user_stats (user_id, xp_total)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  -- Add XP and reputation
  UPDATE public.forum_user_stats SET
    xp_total = COALESCE(xp_total, 0) + p_xp_amount,
    reputation_score = COALESCE(reputation_score, 0) + v_rep,
    updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total, reputation_score INTO v_new_xp, v_new_rep;

  -- Log event
  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, metadata)
  VALUES (p_user_id, 'admin_bonus', p_xp_amount, v_rep, 'general',
    jsonb_build_object('reason', p_reason, 'admin_id', v_admin_id));

  -- Recalculate tier based on new XP
  UPDATE public.forum_user_stats fus SET
    tier = rt.key,
    vote_weight = rt.vote_weight,
    trust_level = rt.level
  FROM (
    SELECT key, vote_weight, level FROM public.reputation_tiers
    WHERE min_xp <= v_new_xp ORDER BY level DESC LIMIT 1
  ) rt
  WHERE fus.user_id = p_user_id;

  -- Recheck achievements
  PERFORM public.check_user_achievements(p_user_id);

  RETURN jsonb_build_object('ok', true, 'xp_added', p_xp_amount, 'rep_added', v_rep, 'new_xp', v_new_xp, 'new_reputation', v_new_rep);
END;
$$;

-- Grant execute to authenticated (function checks super_admin internally)
GRANT EXECUTE ON FUNCTION public.admin_add_xp(UUID, INTEGER, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_xp(UUID, INTEGER, TEXT, INTEGER) TO service_role;

-- ─── Patch deduct_user_xp: only admins can call ─────────────────
CREATE OR REPLACE FUNCTION public.deduct_user_xp(
  p_user_id UUID,
  p_amount INTEGER,
  p_reason TEXT DEFAULT 'penalty',
  p_metadata JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_new_xp INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Только администратор может списывать XP');
  END IF;

  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_must_be_positive');
  END IF;

  INSERT INTO public.forum_user_stats (user_id, xp_total)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.forum_user_stats
  SET xp_total = GREATEST(0, COALESCE(xp_total, 0) - p_amount),
      reputation_score = GREATEST(0, COALESCE(reputation_score, 0) - LEAST(p_amount / 2, 10)),
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING xp_total INTO v_new_xp;

  INSERT INTO public.reputation_events (user_id, event_type, xp_delta, reputation_delta, category, metadata)
  VALUES (p_user_id, p_reason, -p_amount, -LEAST(p_amount / 2, 10), 'penalty', p_metadata);

  -- Recalculate tier (may downgrade)
  UPDATE public.forum_user_stats fus SET
    tier = rt.key,
    vote_weight = rt.vote_weight,
    trust_level = rt.level
  FROM (
    SELECT key, vote_weight, level FROM public.reputation_tiers
    WHERE min_xp <= v_new_xp ORDER BY level DESC LIMIT 1
  ) rt
  WHERE fus.user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'xp_deducted', p_amount, 'new_xp', v_new_xp);
END;
$$;
