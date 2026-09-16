-- Suno V6-only generator, editable provider credits / sale price, and auditable generation logs.
-- Additive migration: no existing rows or objects are removed.

ALTER TABLE public.addon_services
  ADD COLUMN IF NOT EXISTS provider TEXT,
  ADD COLUMN IF NOT EXISTS provider_operation TEXT,
  ADD COLUMN IF NOT EXISTS provider_model TEXT,
  ADD COLUMN IF NOT EXISTS provider_options JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS base_cost_credits NUMERIC(12, 4) NOT NULL DEFAULT 0;

INSERT INTO public.ai_models (name, version, description, is_hot, is_active, sort_order)
SELECT 'Suno', 'V6', 'Suno V6: до 5000 символов текста, стиль до 1000 символов', true, true, 1
WHERE NOT EXISTS (
  SELECT 1 FROM public.ai_models WHERE name = 'Suno' AND upper(replace(version, '.', '_')) = 'V6'
);

UPDATE public.ai_models
SET is_active = (upper(replace(version, '.', '_')) = 'V6'),
    is_hot = (upper(replace(version, '.', '_')) = 'V6'),
    sort_order = CASE WHEN upper(replace(version, '.', '_')) = 'V6' THEN 1 ELSE sort_order END
WHERE name = 'Suno';

INSERT INTO public.addon_services (
  name, name_ru, description, price_aipci, base_cost_credits, price_rub,
  provider, provider_operation, provider_model, icon, is_active, sort_order
)
VALUES (
  'generate_music_v6',
  'Создание музыки Suno V6',
  'Базовая генерация Suno V6: один запрос создаёт два варианта трека',
  12, 12,
  COALESCE((SELECT value::integer FROM public.settings WHERE key = 'generation_price' LIMIT 1), 28),
  'sunoapi', 'generate', 'V6',
  'music',
  true,
  10
)
ON CONFLICT (name) DO NOTHING;

UPDATE public.addon_services
SET price_aipci = 10, base_cost_credits = 10,
    provider = 'sunoapi', provider_operation = 'upload_cover', provider_model = 'V6'
WHERE name = 'upload_cover' AND COALESCE(price_aipci, 0) = 0;

UPDATE public.addon_services
SET price_aipci = 0.4, base_cost_credits = 0.4, provider = 'sunoapi'
WHERE name IN ('convert_wav', 'generate_lyrics', 'create_prompt', 'auto_prepare')
  AND COALESCE(price_aipci, 0) = 0;

UPDATE public.addon_services
SET price_aipci = 2, base_cost_credits = 2,
    provider = 'sunoapi', provider_operation = 'music_video', provider_model = 'V6'
WHERE name = 'music_video' AND COALESCE(price_aipci, 0) = 0;

ALTER TABLE public.generation_logs
  ADD COLUMN IF NOT EXISTS service_id UUID REFERENCES public.addon_services(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS service_name TEXT,
  ADD COLUMN IF NOT EXISTS request_id UUID,
  ADD COLUMN IF NOT EXISTS provider TEXT,
  ADD COLUMN IF NOT EXISTS provider_operation TEXT,
  ADD COLUMN IF NOT EXISTS provider_model TEXT,
  ADD COLUMN IF NOT EXISTS sale_price_rub NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discount_rub NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS refund_rub NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS base_cost_credits NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS generation_params JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_generation_logs_service_name_created_at
  ON public.generation_logs(service_name, created_at DESC);

CREATE OR REPLACE FUNCTION public.debit_for_generation_v6(
  p_user_id UUID,
  p_addon_service_ids UUID[] DEFAULT '{}',
  p_description TEXT DEFAULT 'Генерация трека Suno V6'
)
RETURNS TABLE(
  new_balance INTEGER,
  amount_debited INTEGER,
  generation_service_id UUID,
  generation_sale_price_rub INTEGER,
  generation_base_cost_credits NUMERIC,
  discount_amount INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_service_id UUID;
  v_generation_price INTEGER;
  v_base_cost_credits NUMERIC;
  v_discount_percent INTEGER;
  v_discount_amount INTEGER := 0;
  v_has_subscription BOOLEAN;
  v_addons_total INTEGER := 0;
  v_sale_price INTEGER;
  v_total INTEGER;
  v_new_balance INTEGER;
BEGIN
  v_caller := (current_setting('request.jwt.claim.sub', true))::uuid;
  IF v_caller IS NULL OR (v_caller != p_user_id AND NOT public.is_admin(v_caller)) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT id, price_rub, base_cost_credits
  INTO v_service_id, v_generation_price, v_base_cost_credits
  FROM public.addon_services
  WHERE name = 'generate_music_v6' AND is_active = true
  LIMIT 1;

  IF v_service_id IS NULL OR COALESCE(v_generation_price, 0) <= 0 THEN
    RAISE EXCEPTION 'Generation service is unavailable';
  END IF;

  SELECT COALESCE((value)::integer, 20) INTO v_discount_percent
  FROM public.settings WHERE key = 'subscriber_discount_percent' LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM public.user_subscriptions s
    WHERE s.user_id = p_user_id
      AND s.status IN ('active', 'canceled')
      AND s.current_period_end > now()
  ) INTO v_has_subscription;

  v_sale_price := v_generation_price;
  IF v_has_subscription AND v_discount_percent > 0 THEN
    v_discount_amount := v_generation_price * v_discount_percent / 100;
    v_sale_price := v_generation_price - v_discount_amount;
  END IF;

  IF array_length(p_addon_service_ids, 1) > 0 THEN
    SELECT COALESCE(SUM(price_rub), 0)::integer INTO v_addons_total
    FROM public.addon_services
    WHERE id = ANY(p_addon_service_ids) AND is_active = true;
  END IF;

  v_total := v_sale_price + v_addons_total;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;

  UPDATE public.profiles
  SET balance = balance - v_total
  WHERE user_id = p_user_id AND balance >= v_total
  RETURNING balance INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, balance_before, balance_after)
  VALUES
    (p_user_id, -v_total, 'debit', p_description, v_new_balance + v_total, v_new_balance);

  RETURN QUERY SELECT
    v_new_balance,
    v_total,
    v_service_id,
    v_sale_price,
    COALESCE(v_base_cost_credits, 0),
    v_discount_amount;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debit_for_generation_v6(UUID, UUID[], TEXT) TO authenticated;

COMMENT ON FUNCTION public.debit_for_generation_v6 IS
  'Atomic Suno V6 debit using editable addon_services base API credits and RUB sale price.';
