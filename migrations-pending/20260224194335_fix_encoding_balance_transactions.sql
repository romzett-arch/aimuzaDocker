-- Исправление кодировки: восстановление ВСЕХ повреждённых описаний в balance_transactions
-- Полная версия — покрывает все типы транзакций

SET client_encoding = 'UTF8';

-- ============================================================
-- 1. radio_slot + debit (ставка на слот)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Ставка ' || abs(bt.amount) || ' ₽ на слот #' || rs.slot_number
FROM public.radio_slots rs
WHERE bt.reference_type = 'radio_slot'
  AND bt.type = 'debit'
  AND bt.reference_id = rs.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 2. radio_bid + refund (возврат ставки)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Возврат предыдущей ставки на слот #' || rs.slot_number
FROM public.radio_bids rb
JOIN public.radio_slots rs ON rs.id = rb.slot_id
WHERE bt.reference_type = 'radio_bid'
  AND bt.type = 'refund'
  AND bt.reference_id = rb.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 3. topup (пополнение из payments)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Пополнение баланса на ' || p.amount || ' ₽ (' || COALESCE(p.payment_system, 'robokassa') || ')'
FROM public.payments p
WHERE bt.reference_type = 'payment'
  AND bt.reference_id = p.id
  AND bt.type = 'topup'
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 4. admin — административные операции (reference_type = radio_slot)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Корректировка ' || abs(bt.amount) || ' ₽ слот #' || rs.slot_number
FROM public.radio_slots rs
WHERE bt.type = 'admin'
  AND bt.reference_type = 'radio_slot'
  AND bt.reference_id = rs.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 5. admin — без привязки к радиослоту
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Административная операция: ' || abs(bt.amount) || ' ₽'
WHERE bt.type = 'admin'
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]')
  AND bt.reference_type IS DISTINCT FROM 'radio_slot';

-- ============================================================
-- 6. generation — генерация треков
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Генерация трека: ' || COALESCE(t.title, 'Без названия')
FROM public.tracks t
WHERE bt.type = 'generation'
  AND bt.reference_type = 'track'
  AND bt.reference_id = t.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

UPDATE public.balance_transactions bt
SET description = 'Генерация трека'
WHERE bt.type = 'generation'
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]')
  AND (bt.reference_type IS NULL OR bt.reference_type != 'track');

-- ============================================================
-- 7. refund — возвраты за генерацию (reference_type = track)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Возврат за генерацию: ' || COALESCE(t.title, 'трек')
FROM public.tracks t
WHERE bt.type = 'refund'
  AND bt.reference_type = 'track'
  AND bt.reference_id = t.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 8. refund — возвраты за платежи (reference_type = payment)
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Возврат средств: ' || abs(bt.amount) || ' ₽'
WHERE bt.type = 'refund'
  AND bt.reference_type = 'payment'
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 9. purchase — продвижение треков
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Продвижение трека: ' || abs(bt.amount) || ' ₽'
WHERE bt.type = 'purchase'
  AND bt.reference_type = 'promotion'
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 10. item_purchase / sale_income — маркетплейс
-- ============================================================

UPDATE public.balance_transactions bt
SET description = 'Покупка: ' || COALESCE(si.title, 'товар')
FROM public.store_items si
WHERE bt.type = 'item_purchase'
  AND bt.reference_type = 'store_item'
  AND bt.reference_id = si.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

UPDATE public.balance_transactions bt
SET description = 'Продажа: ' || COALESCE(si.title, 'товар')
FROM public.store_items si
WHERE bt.type = 'sale_income'
  AND bt.reference_type = 'store_item'
  AND bt.reference_id = si.id
  AND (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 11. Финальный fallback — всё, что осталось повреждённым
-- ============================================================

UPDATE public.balance_transactions bt
SET description = CASE bt.type
  WHEN 'generation'     THEN 'Генерация трека'
  WHEN 'separation'     THEN 'Разделение аудио'
  WHEN 'video'          THEN 'Промо-видео'
  WHEN 'lyrics_gen'     THEN 'Генерация текста'
  WHEN 'lyrics_deposit' THEN 'Депозит текста'
  WHEN 'track_deposit'  THEN 'Депозит трека'
  WHEN 'forum_ai'       THEN 'Форум AI'
  WHEN 'addon_service'  THEN 'Дополнительная услуга'
  WHEN 'beat_purchase'  THEN 'Покупка бита'
  WHEN 'prompt_purchase' THEN 'Покупка промпта'
  WHEN 'item_purchase'  THEN 'Покупка товара'
  WHEN 'sale_income'    THEN 'Доход от продажи'
  WHEN 'topup'          THEN 'Пополнение баланса'
  WHEN 'refund'         THEN 'Возврат средств'
  WHEN 'debit'          THEN 'Списание: ' || abs(bt.amount) || ' ₽'
  WHEN 'admin'          THEN 'Административная операция'
  WHEN 'purchase'       THEN 'Покупка услуги'
  ELSE 'Операция: ' || bt.type
END
WHERE (bt.description ~ '\?' OR bt.description !~ '^[А-Яа-яЁёA-Za-z0-9]');

-- ============================================================
-- 12. Таблица payments: исправление описаний
-- ============================================================

UPDATE public.payments
SET description = 'Пополнение баланса на ' || amount || ' ₽'
WHERE description IS NOT NULL
  AND (description ~ '\?' OR description !~ '^[А-Яа-яЁёA-Za-z0-9]');

UPDATE public.payments
SET description = 'Пополнение баланса на ' || amount || ' ₽'
WHERE description IS NULL;
