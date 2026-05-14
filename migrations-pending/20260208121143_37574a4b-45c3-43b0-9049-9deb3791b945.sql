-- Centralized balance transaction log
-- Every balance change (deduction or topup) gets recorded here
CREATE TABLE public.balance_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  amount INTEGER NOT NULL, -- positive = income, negative = spending
  balance_after INTEGER, -- balance after this transaction
  type TEXT NOT NULL, -- 'topup', 'generation', 'separation', 'video', 'lyrics_gen', 'lyrics_deposit', 'track_deposit', 'beat_purchase', 'prompt_purchase', 'item_purchase', 'forum_ai', 'refund', 'admin', 'sale_income'
  description TEXT NOT NULL,
  reference_id UUID, -- ID of the related entity (track_id, payment_id, etc.)
  reference_type TEXT, -- 'track', 'payment', 'audio_separation', 'promo_video', 'lyrics_deposit', 'beat', 'prompt', 'store_item', 'forum_topic'
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for fast user queries
CREATE INDEX idx_balance_transactions_user_id ON public.balance_transactions(user_id);
CREATE INDEX idx_balance_transactions_user_created ON public.balance_transactions(user_id, created_at DESC);
CREATE INDEX idx_balance_transactions_type ON public.balance_transactions(type);

-- Enable RLS
ALTER TABLE public.balance_transactions ENABLE ROW LEVEL SECURITY;

-- Users can only see their own transactions
CREATE POLICY "Users can view own transactions"
  ON public.balance_transactions FOR SELECT
  USING (auth.uid() = user_id);

-- Only service role can insert (via edge functions)
CREATE POLICY "Service role can insert transactions"
  ON public.balance_transactions FOR INSERT
  WITH CHECK (true);

-- Backfill from existing data: generation_logs (completed)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  gl.user_id,
  -gl.aipci_spent,
  'generation',
  COALESCE('Генерация трека: ' || t.title, 'Генерация трека'),
  gl.track_id,
  'track',
  gl.created_at
FROM public.generation_logs gl
LEFT JOIN public.tracks t ON t.id = gl.track_id
WHERE gl.status = 'completed' AND gl.aipci_spent > 0;

-- Backfill: generation_logs (failed with refund)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  gl.user_id,
  gl.aipci_spent,
  'refund',
  COALESCE('Возврат за генерацию: ' || t.title, 'Возврат за неудачную генерацию'),
  gl.track_id,
  'track',
  gl.created_at
FROM public.generation_logs gl
LEFT JOIN public.tracks t ON t.id = gl.track_id
WHERE gl.status = 'failed' AND gl.aipci_spent > 0;

-- Backfill: payments (topups)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  p.user_id,
  p.amount,
  'topup',
  COALESCE(p.description, 'Пополнение баланса') || ' (' || p.payment_system || ')',
  p.id,
  'payment',
  p.created_at
FROM public.payments p
WHERE p.status = 'completed';

-- Backfill: audio_separations
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  a.user_id,
  -a.price_aipci,
  'separation',
  'Разделение аудио (' || a.type || ')',
  a.id,
  'audio_separation',
  a.created_at
FROM public.audio_separations a
WHERE a.price_aipci > 0;

-- Backfill: promo_videos
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pv.user_id,
  -pv.price_aipci,
  'video',
  'Промо-видео',
  pv.track_id,
  'track',
  pv.created_at
FROM public.promo_videos pv
WHERE pv.price_aipci > 0 AND pv.status != 'failed';

-- Backfill: lyrics_deposits
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ld.user_id,
  -ld.price_aipci,
  'lyrics_deposit',
  'Депозит текста',
  ld.id,
  'lyrics_deposit',
  ld.created_at
FROM public.lyrics_deposits ld
WHERE ld.price_aipci > 0 AND ld.status = 'completed';

-- Backfill: beat_purchases (buyer side)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  bp.buyer_id,
  -bp.price,
  'beat_purchase',
  'Покупка бита',
  bp.beat_id,
  'beat',
  bp.created_at
FROM public.beat_purchases bp
WHERE bp.status = 'completed';

-- Backfill: beat_purchases (seller income)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  bp.seller_id,
  bp.price,
  'sale_income',
  'Продажа бита',
  bp.beat_id,
  'beat',
  bp.created_at
FROM public.beat_purchases bp
WHERE bp.status = 'completed';

-- Backfill: prompt_purchases (buyer)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pp.buyer_id,
  -pp.price,
  'prompt_purchase',
  'Покупка промпта',
  pp.prompt_id,
  'prompt',
  pp.created_at
FROM public.prompt_purchases pp
WHERE pp.status = 'completed';

-- Backfill: prompt_purchases (seller)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  pp.seller_id,
  pp.price,
  'sale_income',
  'Продажа промпта',
  pp.prompt_id,
  'prompt',
  pp.created_at
FROM public.prompt_purchases pp
WHERE pp.status = 'completed';

-- Backfill: item_purchases (buyer)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ip.buyer_id,
  -ip.price,
  'item_purchase',
  'Покупка товара',
  ip.store_item_id,
  'store_item',
  ip.created_at
FROM public.item_purchases ip
WHERE ip.status = 'completed';

-- Backfill: item_purchases (seller)
INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_id, reference_type, created_at)
SELECT 
  ip.seller_id,
  ip.net_amount,
  'sale_income',
  'Продажа товара',
  ip.store_item_id,
  'store_item',
  ip.created_at
FROM public.item_purchases ip
WHERE ip.status = 'completed' AND ip.net_amount > 0;

-- Enable realtime for live updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.balance_transactions;