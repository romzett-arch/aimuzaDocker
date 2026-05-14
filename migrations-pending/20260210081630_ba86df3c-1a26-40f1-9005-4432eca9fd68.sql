
-- 1. Harden purchase functions: use auth.uid() directly instead of accepting buyer_id

CREATE OR REPLACE FUNCTION public.process_beat_purchase(p_beat_id UUID, p_buyer_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_beat RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Explicit auth check
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_beat FROM public.store_beats WHERE id = p_beat_id AND is_active = true;
  IF v_beat IS NULL THEN RAISE EXCEPTION 'Beat not found or not available'; END IF;
  IF v_beat.seller_id = p_buyer_id THEN RAISE EXCEPTION 'Cannot purchase your own beat'; END IF;

  v_platform_fee := ROUND(v_beat.price * 0.1);
  v_net_amount := v_beat.price - v_platform_fee;

  UPDATE public.profiles SET balance = balance - v_beat.price
  WHERE user_id = p_buyer_id AND balance >= v_beat.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.beat_purchases (buyer_id, beat_id, seller_id, price, license_type)
  VALUES (p_buyer_id, p_beat_id, v_beat.seller_id, v_beat.price, v_beat.license_type)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_beat.seller_id, v_beat.price, 'beat', v_purchase_id, v_platform_fee, v_net_amount);

  UPDATE public.profiles SET balance = balance + v_net_amount WHERE user_id = v_beat.seller_id;
  UPDATE public.store_beats SET sales_count = sales_count + 1 WHERE id = p_beat_id;

  IF v_beat.is_exclusive THEN
    UPDATE public.store_beats SET is_active = false WHERE id = p_beat_id;
  END IF;

  RETURN v_purchase_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_prompt_purchase(p_prompt_id UUID, p_buyer_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prompt RECORD;
  v_purchase_id UUID;
  v_platform_fee INTEGER;
  v_net_amount INTEGER;
BEGIN
  -- Explicit auth check
  IF p_buyer_id != auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: buyer_id must match authenticated user';
  END IF;

  SELECT * INTO v_prompt FROM public.user_prompts WHERE id = p_prompt_id AND is_public = true AND price > 0;
  IF v_prompt IS NULL THEN RAISE EXCEPTION 'Prompt not found or not for sale'; END IF;
  IF v_prompt.user_id = p_buyer_id THEN RAISE EXCEPTION 'Cannot purchase your own prompt'; END IF;
  IF EXISTS (SELECT 1 FROM public.prompt_purchases WHERE prompt_id = p_prompt_id AND buyer_id = p_buyer_id) THEN
    RAISE EXCEPTION 'Already purchased';
  END IF;

  v_platform_fee := ROUND(v_prompt.price * 0.1);
  v_net_amount := v_prompt.price - v_platform_fee;

  UPDATE public.profiles SET balance = balance - v_prompt.price
  WHERE user_id = p_buyer_id AND balance >= v_prompt.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.prompt_purchases (buyer_id, prompt_id, seller_id, price)
  VALUES (p_buyer_id, p_prompt_id, v_prompt.user_id, v_prompt.price)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount)
  VALUES (v_prompt.user_id, v_prompt.price, 'prompt', v_purchase_id, v_platform_fee, v_net_amount);

  UPDATE public.profiles SET balance = balance + v_net_amount WHERE user_id = v_prompt.user_id;
  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;

  RETURN v_purchase_id;
END;
$$;

-- 2. Fix forum_user_stats: respect hide_forum_activity privacy setting
-- Remove duplicate/overly permissive SELECT policies
DROP POLICY IF EXISTS "Anyone can view forum stats" ON public.forum_user_stats;
DROP POLICY IF EXISTS "Forum stats readable by all authenticated" ON public.forum_user_stats;

-- New policy: users see their own full stats, others only if not hidden
CREATE POLICY "Users can view visible forum stats"
  ON public.forum_user_stats FOR SELECT
  USING (
    auth.uid() = user_id
    OR is_admin(auth.uid())
    OR hide_forum_activity IS NOT TRUE
  );
