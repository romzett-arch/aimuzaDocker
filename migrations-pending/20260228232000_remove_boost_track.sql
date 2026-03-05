-- Удаление функции буста треков (полное удаление).
-- 1. Деактивировать addon_services для boost_track_*
-- 2. Удалить RPC purchase_track_boost

UPDATE public.addon_services
SET is_active = false
WHERE name IN ('boost_track_1h', 'boost_track_6h', 'boost_track_24h');

DROP FUNCTION IF EXISTS public.purchase_track_boost(uuid, integer);
