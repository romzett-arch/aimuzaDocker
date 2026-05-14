-- One-time cleanup for testing: deals, stats, lyrics, prompts
-- Tracks (tracks.lyrics) NOT touched. Only lyrics_items (imported/created texts) cleared.

BEGIN;

-- 1. Refund buyers (add back purchase price)
UPDATE public.profiles p
SET balance = balance + sub.total
FROM (
  SELECT buyer_id, SUM(price) AS total
  FROM public.item_purchases
  GROUP BY buyer_id
) sub
WHERE p.user_id = sub.buyer_id;

-- 2. Deduct from sellers (approved/available earnings), floor at 0
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'seller_earnings'
      AND column_name = 'user_id'
  ) THEN
    EXECUTE $sql$
      UPDATE public.profiles p
      SET balance = GREATEST(0, balance - sub.total)
      FROM (
        SELECT user_id, SUM(net_amount) AS total
        FROM public.seller_earnings
        WHERE status IN ('available', 'approved')
        GROUP BY user_id
      ) sub
      WHERE p.user_id = sub.user_id
    $sql$;
  ELSE
    EXECUTE $sql$
      UPDATE public.profiles p
      SET balance = GREATEST(0, balance - sub.total)
      FROM (
        SELECT seller_id, SUM(net_amount) AS total
        FROM public.seller_earnings
        WHERE status IN ('available', 'approved')
        GROUP BY seller_id
      ) sub
      WHERE p.user_id = sub.seller_id
    $sql$;
  END IF;
END $$;

-- 3. Delete balance_transactions (purchases, sales, refunds)
DELETE FROM public.balance_transactions
WHERE type IN ('item_purchase', 'sale_income', 'refund');

-- 4. Delete seller_earnings
DELETE FROM public.seller_earnings;

-- 5. Delete item_purchases
DELETE FROM public.item_purchases;

-- 6. Delete store_items (lyrics + prompts; beats left)
DELETE FROM public.store_items WHERE item_type IN ('lyrics', 'prompt');

-- 7. Delete lyrics_deposits (references lyrics_items)
DELETE FROM public.lyrics_deposits;

-- 8. Delete lyrics_items (all texts, including imported from tracks)
DELETE FROM public.lyrics_items;

-- 9. Delete user_prompts
DELETE FROM public.user_prompts;

-- 10. Delete notifications (deals, item_sold)
DELETE FROM public.notifications
WHERE target_type = 'item_purchase'
   OR type IN ('item_sold', 'deal_pending_review', 'deal_approved', 'deal_rejected');

COMMIT;
