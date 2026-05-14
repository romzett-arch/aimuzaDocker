-- =====================================================
-- Массовый GRANT EXECUTE для всех RPC, вызываемых из фронтенда
-- Безопасно пропускает отсутствующие в локальной схеме функции
-- =====================================================

DO $$
BEGIN
  IF to_regprocedure('public.record_track_like_update(uuid,integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.record_track_like_update(UUID, INTEGER) TO authenticated;
  END IF;

  IF to_regprocedure('public.record_track_play(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.record_track_play(UUID) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.record_track_play(UUID) TO anon;
  END IF;

  IF to_regprocedure('public.block_user(uuid,text,uuid,text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.block_user(UUID, TEXT, UUID, TEXT) TO authenticated;
  END IF;

  IF to_regprocedure('public.unblock_user(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.unblock_user(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.find_user_by_short_id(text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.find_user_by_short_id(TEXT) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.find_user_by_short_id(TEXT) TO anon;
  END IF;

  IF to_regprocedure('public.create_conversation_with_user(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.create_conversation_with_user(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.process_store_item_purchase(uuid,uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.process_store_item_purchase(UUID, UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.has_purchased_item(uuid,uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.has_purchased_item(UUID, UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.has_purchased_prompt(uuid,uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.has_purchased_prompt(UUID, UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.purchase_ad_free(uuid,integer,integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.purchase_ad_free(UUID, INTEGER, INTEGER) TO authenticated;
  END IF;

  IF to_regprocedure('public.increment_prompt_downloads(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.increment_prompt_downloads(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_boosted_tracks(integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.get_boosted_tracks(INTEGER) TO anon;
  END IF;

  IF to_regprocedure('public.get_track_by_share_token(text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_track_by_share_token(TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION public.get_track_by_share_token(TEXT) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_track_prompt_if_accessible(uuid,uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_track_prompt_if_accessible(UUID, UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_track_prompt_info(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_track_prompt_info(UUID) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.get_track_prompt_info(UUID) TO anon;
  END IF;

  IF to_regprocedure('public.get_smart_feed(uuid,text,uuid,integer,integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_smart_feed(UUID, TEXT, UUID, INTEGER, INTEGER) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.get_smart_feed(UUID, TEXT, UUID, INTEGER, INTEGER) TO anon;
  END IF;

  IF to_regprocedure('public.get_user_stats(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_user_stats(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.process_payment_refund(uuid,integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.process_payment_refund(UUID, INTEGER) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_or_create_referral_code(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_or_create_referral_code(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.is_admin(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.is_admin(UUID) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.is_admin(UUID) TO anon;
  END IF;

  IF to_regprocedure('public.award_xp(uuid,text,text,uuid,jsonb)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.award_xp(UUID, TEXT, TEXT, UUID, JSONB) TO authenticated;
  END IF;

  IF to_regprocedure('public.check_user_achievements(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.check_user_achievements(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_reputation_profile(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_reputation_profile(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.get_reputation_leaderboard(text,integer)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_reputation_leaderboard(TEXT, INTEGER) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.get_reputation_leaderboard(TEXT, INTEGER) TO anon;
  END IF;

  IF to_regprocedure('public.get_economy_health()') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_economy_health() TO authenticated;
  END IF;

  IF to_regprocedure('public.get_creator_earnings_profile(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.get_creator_earnings_profile(UUID) TO authenticated;
  END IF;

  IF to_regprocedure('public.calculate_track_quality(uuid)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.calculate_track_quality(UUID) TO authenticated;
  END IF;
END $$;
