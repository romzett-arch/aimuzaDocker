-- ============================================================
-- PREMIUM SUBSCRIPTIONS — Аудит-фиксы
-- 1. renew_expired_subscriptions: убрать grant authenticated
-- 2. allocate_guaranteed_radio_slots: убрать grant authenticated
-- ============================================================

-- Cron-функции должны вызываться только service_role, не пользователями
REVOKE EXECUTE ON FUNCTION public.renew_expired_subscriptions() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.allocate_guaranteed_radio_slots() FROM authenticated;
