-- Тарифный enforcement: пакет дозагрузки, атомарный учёт upload,
-- серверные ограничения маркетплейса/конкурсов и исправление лимитов депонирования.

-- ─────────────────────────────────────────────────────────────
-- 1. Пакеты дозагрузки треков
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_track_upload_packs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  pack_key TEXT NOT NULL DEFAULT 'track_upload_pack_10',
  tracks_total INTEGER NOT NULL CHECK (tracks_total > 0),
  tracks_used INTEGER NOT NULL DEFAULT 0 CHECK (tracks_used >= 0),
  price_paid INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'consumed', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_track_upload_packs_user_status
  ON public.user_track_upload_packs(user_id, status, created_at);

ALTER TABLE public.user_track_upload_packs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_track_upload_packs'
      AND policyname = 'Users can view own upload packs'
  ) THEN
    CREATE POLICY "Users can view own upload packs"
      ON public.user_track_upload_packs
      FOR SELECT
      USING (auth.uid() = user_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_track_upload_packs'
      AND policyname = 'Admins can manage upload packs'
  ) THEN
    CREATE POLICY "Admins can manage upload packs"
      ON public.user_track_upload_packs
      FOR ALL
      USING (public.is_admin(auth.uid()));
  END IF;
END $$;

ALTER TABLE public.user_track_uploads
  ADD COLUMN IF NOT EXISTS pack_id UUID REFERENCES public.user_track_upload_packs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pack_slot_used BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ;

INSERT INTO public.addon_services (name, name_ru, description, price_rub, icon, is_active, sort_order)
VALUES
  ('boost_track_1h', 'Буст трека 1 час', 'Поднять трек в ленте на 1 час', 49, 'rocket', true, 30),
  ('boost_track_6h', 'Буст трека 6 часов', 'Поднять трек в ленте на 6 часов', 99, 'rocket', true, 31),
  ('boost_track_24h', 'Буст трека 24 часа', 'Поднять трек в ленте на 24 часа', 199, 'rocket', true, 32),
  ('track_upload_pack_10', 'Пакет загрузки 10 треков', '10 дозагрузок сверх месячного лимита подписки', 150, 'music', true, 33)
ON CONFLICT (name) DO UPDATE SET
  name_ru = EXCLUDED.name_ru,
  description = EXCLUDED.description,
  price_rub = EXCLUDED.price_rub,
  icon = EXCLUDED.icon,
  is_active = EXCLUDED.is_active,
  sort_order = EXCLUDED.sort_order,
  updated_at = now();

-- ─────────────────────────────────────────────────────────────
-- 2. Вспомогательные функции авторизации
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.can_manage_user_payload(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_role TEXT := COALESCE(current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_caller IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_caller = p_user_id OR public.is_admin(v_caller);
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 3. Лимиты загрузки: пакет + auth check
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.check_track_upload_limit(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier JSONB;
  v_daily_count INTEGER;
  v_monthly_count INTEGER;
  v_daily_limit INTEGER;
  v_monthly_free INTEGER;
  v_monthly_hard_limit INTEGER;
  v_extra_price INTEGER;
  v_pricing JSONB;
  v_price INTEGER := 0;
  v_is_free_tier BOOLEAN;
  v_nth INTEGER;
  v_item JSONB;
  v_pack_remaining INTEGER := 0;
  v_pack_applied BOOLEAN := false;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('can_upload', false, 'price', 0, 'reason', 'unauthorized');
  END IF;

  v_tier := public.get_user_subscription_tier(p_user_id);
  v_is_free_tier := (v_tier->>'tier_key') = 'free';
  v_daily_limit := COALESCE((v_tier->>'tracks_free_daily')::INTEGER, 0);
  v_monthly_free := COALESCE((v_tier->>'tracks_free_monthly')::INTEGER, 0);
  v_monthly_hard_limit := COALESCE((v_tier->>'tracks_monthly_hard_limit')::INTEGER, 0);
  v_extra_price := COALESCE((v_tier->>'extra_track_price')::INTEGER, 0);
  v_pricing := COALESCE(v_tier->'free_track_pricing', '[]'::jsonb);

  SELECT COUNT(*) INTO v_daily_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND refunded_at IS NULL
    AND upload_date = CURRENT_DATE;

  SELECT COUNT(*) INTO v_monthly_count
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND refunded_at IS NULL
    AND upload_date >= date_trunc('month', CURRENT_DATE)::DATE;

  SELECT COALESCE(SUM(GREATEST(tracks_total - tracks_used, 0)), 0) INTO v_pack_remaining
  FROM public.user_track_upload_packs
  WHERE user_id = p_user_id
    AND status = 'active';

  IF v_monthly_hard_limit > 0 AND v_monthly_count >= v_monthly_hard_limit THEN
    RETURN jsonb_build_object(
      'can_upload', false,
      'price', 0,
      'is_free', false,
      'daily_count', v_daily_count,
      'monthly_count', v_monthly_count,
      'daily_limit', v_daily_limit,
      'monthly_free', v_monthly_free,
      'monthly_hard_limit', v_monthly_hard_limit,
      'reason', 'monthly_limit_reached',
      'tier_key', v_tier->>'tier_key',
      'pack_remaining', v_pack_remaining,
      'pack_applied', false
    );
  END IF;

  IF v_is_free_tier AND jsonb_typeof(v_pricing) = 'array' AND jsonb_array_length(v_pricing) > 0 THEN
    IF v_daily_limit > 0 AND v_daily_count >= v_daily_limit THEN
      RETURN jsonb_build_object(
        'can_upload', false,
        'price', 0,
        'is_free', false,
        'daily_count', v_daily_count,
        'monthly_count', v_monthly_count,
        'daily_limit', v_daily_limit,
        'monthly_free', v_monthly_free,
        'monthly_hard_limit', v_monthly_hard_limit,
        'reason', 'daily_limit_reached',
        'tier_key', v_tier->>'tier_key',
        'pack_remaining', v_pack_remaining,
        'pack_applied', false
      );
    END IF;

    v_nth := v_daily_count + 1;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_pricing)
    LOOP
      IF (v_item->>'nth')::INTEGER = v_nth THEN
        v_price := (v_item->>'price')::INTEGER;
        EXIT;
      END IF;
    END LOOP;

    IF v_price = 0 AND v_nth > 1 THEN
      v_price := COALESCE((v_pricing->(jsonb_array_length(v_pricing) - 1)->>'price')::INTEGER, 0);
    END IF;
  ELSE
    IF v_monthly_count >= v_monthly_free AND v_monthly_free > 0 THEN
      IF v_pack_remaining > 0 THEN
        v_pack_applied := true;
        v_price := 0;
      ELSE
        v_price := v_extra_price;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'can_upload', true,
    'price', v_price,
    'is_free', v_price = 0,
    'daily_count', v_daily_count,
    'monthly_count', v_monthly_count,
    'daily_limit', v_daily_limit,
    'monthly_free', v_monthly_free,
    'monthly_hard_limit', v_monthly_hard_limit,
    'tier_key', v_tier->>'tier_key',
    'pack_remaining', v_pack_remaining,
    'pack_applied', v_pack_applied
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_track_upload_charge(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing RECORD;
  v_limit JSONB;
  v_price INTEGER := 0;
  v_pack_applied BOOLEAN := false;
  v_pack_id UUID;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_existing
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND track_id = p_track_id
    AND refunded_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'price_charged', v_existing.price_charged,
      'is_free', v_existing.is_free,
      'pack_slot_used', v_existing.pack_slot_used
    );
  END IF;

  v_limit := public.check_track_upload_limit(p_user_id);

  IF NOT COALESCE((v_limit->>'can_upload')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('success', false, 'error', COALESCE(v_limit->>'reason', 'upload_not_allowed'), 'limit', v_limit);
  END IF;

  v_price := COALESCE((v_limit->>'price')::INTEGER, 0);
  v_pack_applied := COALESCE((v_limit->>'pack_applied')::BOOLEAN, false);

  IF v_pack_applied THEN
    SELECT id INTO v_pack_id
    FROM public.user_track_upload_packs
    WHERE user_id = p_user_id
      AND status = 'active'
      AND tracks_used < tracks_total
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_pack_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'upload_pack_not_found');
    END IF;

    UPDATE public.user_track_upload_packs
      SET tracks_used = tracks_used + 1,
          status = CASE WHEN tracks_used + 1 >= tracks_total THEN 'consumed' ELSE status END,
          updated_at = now()
      WHERE id = v_pack_id;
  END IF;

  IF v_price > 0 THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_balance_before IS NULL OR v_balance_before < v_price THEN
      RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'required', v_price);
    END IF;

    UPDATE public.profiles
      SET balance = balance - v_price
      WHERE user_id = p_user_id
      RETURNING balance INTO v_balance_after;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (p_user_id, -v_price, 'purchase', 'Загрузка трека (сверх лимита)', v_balance_before, v_balance_after);
  END IF;

  INSERT INTO public.user_track_uploads (user_id, track_id, price_charged, is_free, pack_id, pack_slot_used)
  VALUES (p_user_id, p_track_id, v_price, v_price = 0, v_pack_id, v_pack_applied);

  RETURN jsonb_build_object(
    'success', true,
    'price_charged', v_price,
    'is_free', v_price = 0,
    'pack_slot_used', v_pack_applied
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.revert_track_upload_charge(
  p_user_id UUID,
  p_track_id UUID,
  p_only_unsubmitted BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_upload RECORD;
  v_track RECORD;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_upload
  FROM public.user_track_uploads
  WHERE user_id = p_user_id
    AND track_id = p_track_id
    AND refunded_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_upload IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'upload_record_not_found');
  END IF;

  SELECT id, moderation_status, source_type INTO v_track
  FROM public.tracks
  WHERE id = p_track_id
  LIMIT 1;

  IF p_only_unsubmitted AND v_track IS NOT NULL AND COALESCE(v_track.moderation_status, 'none') <> 'none' THEN
    RETURN jsonb_build_object('success', false, 'error', 'upload_already_submitted');
  END IF;

  IF COALESCE(v_upload.pack_slot_used, false) AND v_upload.pack_id IS NOT NULL THEN
    UPDATE public.user_track_upload_packs
      SET tracks_used = GREATEST(tracks_used - 1, 0),
          status = 'active',
          updated_at = now()
      WHERE id = v_upload.pack_id;
  END IF;

  IF COALESCE(v_upload.price_charged, 0) > 0 THEN
    SELECT balance INTO v_balance_before
    FROM public.profiles
    WHERE user_id = p_user_id
    FOR UPDATE;

    UPDATE public.profiles
      SET balance = balance + v_upload.price_charged
      WHERE user_id = p_user_id
      RETURNING balance INTO v_balance_after;

    INSERT INTO public.balance_transactions
      (user_id, amount, type, description, balance_before, balance_after)
    VALUES
      (p_user_id, v_upload.price_charged, 'refund', 'Возврат за отменённую загрузку трека', v_balance_before, v_balance_after);
  END IF;

  DELETE FROM public.user_track_uploads
  WHERE id = v_upload.id;

  RETURN jsonb_build_object('success', true, 'rolled_back', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_track_upload(
  p_user_id UUID,
  p_track_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.consume_track_upload_charge(p_user_id, p_track_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_track_upload_pack(
  p_user_id UUID,
  p_pack_key TEXT DEFAULT 'track_upload_pack_10'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price INTEGER;
  v_pack_size INTEGER := 10;
  v_balance_before INTEGER;
  v_balance_after INTEGER;
  v_pack_id UUID;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  IF p_pack_key <> 'track_upload_pack_10' THEN
    RETURN jsonb_build_object('success', false, 'error', 'unsupported_pack');
  END IF;

  SELECT price_rub INTO v_price
  FROM public.addon_services
  WHERE name = p_pack_key
    AND is_active = true
  LIMIT 1;

  IF v_price IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'pack_not_found');
  END IF;

  SELECT balance INTO v_balance_before
  FROM public.profiles
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_balance_before IS NULL OR v_balance_before < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'required', v_price, 'balance', COALESCE(v_balance_before, 0));
  END IF;

  UPDATE public.profiles
    SET balance = balance - v_price
    WHERE user_id = p_user_id
    RETURNING balance INTO v_balance_after;

  INSERT INTO public.user_track_upload_packs (user_id, pack_key, tracks_total, price_paid)
  VALUES (p_user_id, p_pack_key, v_pack_size, v_price)
  RETURNING id INTO v_pack_id;

  INSERT INTO public.balance_transactions
    (user_id, amount, type, description, reference_id, reference_type, balance_before, balance_after)
  VALUES
    (p_user_id, -v_price, 'purchase', 'Пакет загрузки 10 треков', v_pack_id, 'track_upload_pack', v_balance_before, v_balance_after);

  RETURN jsonb_build_object(
    'success', true,
    'pack_id', v_pack_id,
    'pack_key', p_pack_key,
    'tracks_total', v_pack_size,
    'price_paid', v_price,
    'new_balance', v_balance_after
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_consume_track_upload_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF COALESCE(NEW.source_type, 'generated') <> 'uploaded' THEN
    RETURN NEW;
  END IF;

  v_result := public.consume_track_upload_charge(NEW.user_id, NEW.id);

  IF NOT COALESCE((v_result->>'success')::BOOLEAN, false) THEN
    RAISE EXCEPTION '%', COALESCE(v_result->>'error', 'track_upload_not_allowed');
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_rollback_track_upload_on_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(OLD.source_type, 'generated') = 'uploaded'
     AND COALESCE(OLD.moderation_status, 'none') = 'none' THEN
    PERFORM public.revert_track_upload_charge(OLD.user_id, OLD.id, true);
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS consume_track_upload_on_insert ON public.tracks;
CREATE TRIGGER consume_track_upload_on_insert
AFTER INSERT ON public.tracks
FOR EACH ROW
EXECUTE FUNCTION public.trg_consume_track_upload_on_insert();

DROP TRIGGER IF EXISTS rollback_track_upload_on_delete ON public.tracks;
CREATE TRIGGER rollback_track_upload_on_delete
BEFORE DELETE ON public.tracks
FOR EACH ROW
EXECUTE FUNCTION public.trg_rollback_track_upload_on_delete();

GRANT EXECUTE ON FUNCTION public.check_track_upload_limit(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_track_upload(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revert_track_upload_charge(UUID, UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_track_upload_pack(UUID, TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 4. Депонирование: auth check + только blockchain-лимит
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.check_deposit_limit(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_free_deposits INTEGER := 0;
  v_used_deposits INTEGER := 0;
BEGIN
  IF NOT public.can_manage_user_payload(p_user_id) THEN
    RETURN jsonb_build_object('free_remaining', 0, 'free_total', 0, 'used_this_month', 0, 'is_free', false, 'error', 'unauthorized');
  END IF;

  SELECT COALESCE(sp.deposits_free_monthly, 0) INTO v_free_deposits
  FROM public.user_subscriptions us
  JOIN public.subscription_plans sp ON sp.id = us.plan_id
  WHERE us.user_id = p_user_id
    AND us.status IN ('active', 'canceled')
    AND us.current_period_end > now()
  ORDER BY us.created_at DESC
  LIMIT 1;

  SELECT COUNT(*) INTO v_used_deposits
  FROM public.track_deposits
  WHERE user_id = p_user_id
    AND method = 'blockchain'
    AND status IN ('processing', 'completed')
    AND created_at >= date_trunc('month', now());

  RETURN jsonb_build_object(
    'free_remaining', GREATEST(0, v_free_deposits - v_used_deposits),
    'free_total', v_free_deposits,
    'used_this_month', v_used_deposits,
    'is_free', v_used_deposits < v_free_deposits
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_deposit_limit(UUID) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 5. Маркетплейс и конкурсы: серверный запрет по тарифу
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.trg_enforce_marketplace_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_access JSONB;
BEGIN
  IF COALESCE(NEW.is_active, true) = false THEN
    RETURN NEW;
  END IF;

  IF public.is_admin(NEW.seller_id) OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  v_access := public.check_marketplace_access(NEW.seller_id);

  IF NOT COALESCE((v_access->>'can_sell')::BOOLEAN, false) THEN
    RAISE EXCEPTION 'marketplace_not_available_for_tier';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_marketplace_access ON public.store_items;
CREATE TRIGGER enforce_marketplace_access
BEFORE INSERT OR UPDATE OF is_active, price, license_type, title, description
ON public.store_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_marketplace_access();

CREATE OR REPLACE FUNCTION public.trg_enforce_contest_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_access JSONB;
BEGIN
  IF public.is_admin(NEW.user_id) OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  v_access := public.check_contest_access(NEW.user_id);

  IF NOT COALESCE((v_access->>'can_participate')::BOOLEAN, false) THEN
    RAISE EXCEPTION 'contest_not_available_for_tier';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_contest_access ON public.contest_entries;
CREATE TRIGGER enforce_contest_access
BEFORE INSERT ON public.contest_entries
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_contest_access();
