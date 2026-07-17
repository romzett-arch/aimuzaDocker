-- Forum & Community reliability: actor integrity, atomic admin operations,
-- configuration-backed Hub logic, and protection from destructive category deletes.

ALTER TABLE public.forum_topics DROP CONSTRAINT IF EXISTS forum_topics_category_id_fkey;
ALTER TABLE public.forum_topics
  ADD CONSTRAINT forum_topics_category_id_fkey
  FOREIGN KEY (category_id) REFERENCES public.forum_categories(id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION public.forum_admin_delete_category(p_category_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_topics integer;
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.settings
    WHERE key = 'forum_voting_category_id'
      AND trim(both '"' from value::text) = p_category_id::text
  ) THEN
    RAISE EXCEPTION 'Системную категорию голосования удалять нельзя';
  END IF;

  SELECT count(*) INTO v_topics FROM public.forum_topics WHERE category_id = p_category_id;
  IF v_topics > 0 THEN
    RAISE EXCEPTION 'Сначала перенесите % тем из категории', v_topics;
  END IF;

  DELETE FROM public.forum_categories WHERE id = p_category_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Категория не найдена'; END IF;
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_admin_reorder_categories(p_order jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_item jsonb;
  v_count integer := 0;
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  IF jsonb_typeof(p_order) <> 'array' OR jsonb_array_length(p_order) > 200 THEN
    RAISE EXCEPTION 'Некорректный порядок категорий';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_order)
  LOOP
    UPDATE public.forum_categories
    SET sort_order = (v_item->>'sort_order')::integer, updated_at = now()
    WHERE id = (v_item->>'id')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Категория не найдена: %', v_item->>'id'; END IF;
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'updated', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_admin_merge_tags(p_source_id uuid, p_target_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_moved integer;
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  IF p_source_id = p_target_id THEN RAISE EXCEPTION 'Выберите разные теги'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.forum_tags WHERE id = p_source_id)
     OR NOT EXISTS (SELECT 1 FROM public.forum_tags WHERE id = p_target_id) THEN
    RAISE EXCEPTION 'Тег не найден';
  END IF;

  INSERT INTO public.forum_topic_tags(topic_id, tag_id)
  SELECT topic_id, p_target_id FROM public.forum_topic_tags WHERE tag_id = p_source_id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_moved = ROW_COUNT;
  DELETE FROM public.forum_tags WHERE id = p_source_id;
  RETURN jsonb_build_object('success', true, 'moved', v_moved);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_resolve_report(
  p_report_id uuid,
  p_action text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_report public.forum_reports%ROWTYPE;
  v_expiry_days integer := 90;
  v_quote text;
BEGIN
  IF v_actor IS NULL OR NOT (
    public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin') OR public.has_role(v_actor, 'moderator')
  ) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;
  IF p_action NOT IN ('dismiss', 'hide', 'hide_warn') THEN RAISE EXCEPTION 'Некорректное действие'; END IF;

  SELECT * INTO v_report FROM public.forum_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Жалоба не найдена'; END IF;
  IF v_report.status <> 'pending' THEN RAISE EXCEPTION 'Жалоба уже обработана'; END IF;

  IF p_action IN ('hide', 'hide_warn') THEN
    IF v_report.target_type = 'topic' THEN
      UPDATE public.forum_topics SET is_hidden = true, hidden_by = v_actor, hidden_at = now(), hidden_reason = COALESCE(NULLIF(trim(p_reason), ''), 'Нарушение правил') WHERE id = v_report.target_id;
    ELSIF v_report.target_type = 'post' THEN
      UPDATE public.forum_posts SET is_hidden = true, hidden_by = v_actor, hidden_at = now(), hidden_reason = COALESCE(NULLIF(trim(p_reason), ''), 'Нарушение правил') WHERE id = v_report.target_id;
    ELSE
      RAISE EXCEPTION 'Неподдерживаемый тип жалобы';
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Контент жалобы не найден'; END IF;
  END IF;

  IF p_action = 'hide_warn' THEN
    IF v_report.target_user_id IS NULL THEN RAISE EXCEPTION 'Не определён автор контента'; END IF;
    SELECT COALESCE(
      CASE WHEN jsonb_typeof(value) = 'number' THEN (value::text)::integer
           WHEN jsonb_typeof(value) = 'string' THEN trim(both '"' from value::text)::integer END,
      90
    ) INTO v_expiry_days FROM public.forum_automod_settings WHERE key = 'warn_expiry_days';
    v_expiry_days := COALESCE(v_expiry_days, 90);
    v_quote := left(COALESCE(v_report.content_snapshot, ''), 200);

    INSERT INTO public.forum_warnings(user_id, moderator_id, issued_by, reason, severity, expires_at)
    VALUES (
      v_report.target_user_id, v_actor, v_actor,
      'Нарушение правил форума: ' || COALESCE(NULLIF(trim(p_reason), ''), 'Нарушение правил') ||
        CASE WHEN v_quote <> '' THEN E'\n\nЦитата: «' || v_quote || CASE WHEN length(v_report.content_snapshot) > 200 THEN '…' ELSE '' END || '»' ELSE '' END,
      'warning', now() + make_interval(days => v_expiry_days)
    );
  END IF;

  UPDATE public.forum_reports
  SET status = CASE WHEN p_action = 'dismiss' THEN 'dismissed' ELSE 'resolved' END,
      moderator_id = v_actor,
      resolution = COALESCE(NULLIF(trim(p_reason), ''), p_action),
      resolved_at = now()
  WHERE id = p_report_id;

  INSERT INTO public.forum_mod_logs(moderator_id, action, target_type, target_id, reason, details)
  VALUES (v_actor, 'report_' || p_action, v_report.target_type, v_report.target_id, p_reason, jsonb_build_object('report_id', p_report_id));

  RETURN jsonb_build_object('success', true, 'status', CASE WHEN p_action = 'dismiss' THEN 'dismissed' ELSE 'resolved' END);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_purchase_promo(
  p_user_id uuid,
  p_promo_type text,
  p_category_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_settings jsonb;
  v_price integer;
  v_duration integer;
  v_balance integer;
  v_active_count integer;
  v_max_active integer;
  v_slot_id uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  IF p_user_id IS DISTINCT FROM v_actor THEN RAISE EXCEPTION 'Нельзя купить промо для другого пользователя'; END IF;

  SELECT value INTO v_settings FROM public.forum_automod_settings WHERE key = 'promo_settings';
  IF v_settings IS NULL OR NOT COALESCE((v_settings->>'enabled')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Промо-реклама временно недоступна');
  END IF;
  IF p_promo_type NOT IN ('text', 'banner', 'pinned') THEN RAISE EXCEPTION 'Неверный тип промо'; END IF;
  v_price := (v_settings->'prices'->>p_promo_type)::integer;
  v_duration := (v_settings->'durations'->>p_promo_type)::integer;
  IF v_price IS NULL OR v_price < 0 OR v_duration IS NULL OR v_duration < 1 THEN RAISE EXCEPTION 'Некорректная конфигурация промо'; END IF;

  IF jsonb_array_length(COALESCE(v_settings->'allowed_categories', '[]'::jsonb)) > 0 AND (
    p_category_id IS NULL OR NOT (v_settings->'allowed_categories' ? p_category_id::text)
  ) THEN RAISE EXCEPTION 'Промо запрещено в выбранной категории'; END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE user_id = v_actor FOR UPDATE;
  IF v_balance IS NULL OR v_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Недостаточно средств', 'required', v_price, 'balance', COALESCE(v_balance, 0));
  END IF;
  v_max_active := COALESCE((v_settings->>'max_active_per_user')::integer, 3);
  SELECT count(*) INTO v_active_count FROM public.forum_promo_slots WHERE user_id = v_actor AND status IN ('pending_content', 'pending_moderation', 'approved');
  IF v_active_count >= v_max_active THEN RETURN jsonb_build_object('success', false, 'error', 'Достигнут лимит активных промо'); END IF;

  UPDATE public.profiles SET balance = balance - v_price WHERE user_id = v_actor;
  INSERT INTO public.forum_promo_slots(user_id, promo_type, status, price_rub, duration_days, category_id)
  VALUES (v_actor, p_promo_type::forum_promo_type, 'pending_content', v_price, v_duration, p_category_id)
  RETURNING id INTO v_slot_id;
  INSERT INTO public.balance_transactions(user_id, amount, type, description, reference_type, reference_id, balance_before, balance_after)
  VALUES (v_actor, -v_price, 'forum_promo_purchase', 'Покупка промо-слота', 'forum_promo_slot', v_slot_id, v_balance, v_balance - v_price);

  RETURN jsonb_build_object('success', true, 'slot_id', v_slot_id, 'price', v_price, 'duration_days', v_duration);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_moderate_promo(
  p_slot_id uuid,
  p_moderator_id uuid,
  p_action text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_slot public.forum_promo_slots%ROWTYPE;
  v_settings jsonb;
  v_refund_percent integer;
  v_refund_amount integer := 0;
  v_balance_before integer;
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;
  IF p_moderator_id IS DISTINCT FROM v_actor THEN RAISE EXCEPTION 'Некорректный модератор'; END IF;
  IF p_action NOT IN ('approve', 'reject') THEN RAISE EXCEPTION 'Неверное действие'; END IF;

  SELECT * INTO v_slot FROM public.forum_promo_slots WHERE id = p_slot_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Промо не найдено'); END IF;
  IF v_slot.status <> 'pending_moderation' THEN RETURN jsonb_build_object('success', false, 'error', 'Промо не на модерации'); END IF;
  SELECT value INTO v_settings FROM public.forum_automod_settings WHERE key = 'promo_settings';

  IF p_action = 'approve' THEN
    UPDATE public.forum_promo_slots SET status='approved', moderated_by=v_actor, moderated_at=now(), starts_at=now(), expires_at=now()+make_interval(days=>v_slot.duration_days) WHERE id=p_slot_id;
  ELSE
    v_refund_percent := CASE WHEN COALESCE((v_settings->>'refund_on_rejection')::boolean, true) THEN LEAST(100, GREATEST(0, COALESCE((v_settings->>'refund_percent')::integer, 100))) ELSE 0 END;
    v_refund_amount := round(v_slot.price_rub * v_refund_percent / 100.0);
    IF v_refund_amount > 0 THEN
      SELECT balance INTO v_balance_before FROM public.profiles WHERE user_id=v_slot.user_id FOR UPDATE;
      UPDATE public.profiles SET balance=COALESCE(balance,0)+v_refund_amount WHERE user_id=v_slot.user_id;
      INSERT INTO public.balance_transactions(user_id,amount,type,description,reference_type,reference_id,balance_before,balance_after)
      VALUES(v_slot.user_id,v_refund_amount,'forum_promo_refund','Возврат за отклонённый промо-слот','forum_promo_slot',p_slot_id,COALESCE(v_balance_before,0),COALESCE(v_balance_before,0)+v_refund_amount);
    END IF;
    UPDATE public.forum_promo_slots SET status='rejected', moderated_by=v_actor, moderated_at=now(), rejection_reason=p_reason, refunded=(v_refund_amount>0), refund_amount=v_refund_amount WHERE id=p_slot_id;
  END IF;

  INSERT INTO public.forum_mod_logs(moderator_id,action,target_type,target_id,reason,details)
  VALUES(v_actor,'promo_'||CASE WHEN p_action='approve' THEN 'approved' ELSE 'rejected' END,'promo',p_slot_id,p_reason,jsonb_build_object('refund',v_refund_amount));
  RETURN jsonb_build_object('success',true,'message',CASE WHEN p_action='approve' THEN 'Промо одобрено и опубликовано' ELSE 'Промо отклонено. Возврат: '||v_refund_amount||' ₽' END);
END;
$$;

REVOKE ALL ON FUNCTION public.forum_admin_delete_category(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_admin_reorder_categories(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_admin_merge_tags(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_resolve_report(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_purchase_promo(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_moderate_promo(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_admin_delete_category(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_reorder_categories(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_merge_tags(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_resolve_report(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_purchase_promo(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_moderate_promo(uuid, uuid, text, text) TO authenticated;
