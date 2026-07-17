DO $$
DECLARE
  v_original text;
  v_updated text;
BEGIN
  SELECT pg_get_functiondef('public.process_store_item_purchase(uuid,uuid)'::regprocedure)
  INTO v_original;
  v_updated := replace(
    v_original,
    'Деньги удержаны, исходник покупателю ещё не открыт.',
    'Деньги удержаны, лицензия покупателю ещё не предоставлена.'
  );
  IF v_updated = v_original THEN
    RAISE EXCEPTION 'Expected pending Marketplace notification wording was not found';
  END IF;
  EXECUTE v_updated;

  SELECT pg_get_functiondef('public.admin_approve_purchase(uuid,text)'::regprocedure)
  INTO v_original;
  v_updated := replace(
    replace(
      v_original,
      'Покупка подтверждена — исходник открыт',
      'Покупка подтверждена — лицензия действует'
    ),
    'AIMUZA завершила сделку. Исходник и зафиксированные условия лицензии доступны в «Моих покупках».',
    'AIMUZA завершила сделку. Лицензия действует; полный исходник, если он был скрыт, и условия доступны в «Моих покупках».'
  );
  IF v_updated = v_original THEN
    RAISE EXCEPTION 'Expected approved Marketplace notification wording was not found';
  END IF;
  EXECUTE v_updated;

  SELECT pg_get_functiondef('public.admin_reject_purchase(uuid,text)'::regprocedure)
  INTO v_original;
  v_updated := replace(
    v_original,
    '₽ возвращено. Исходник не передан.',
    '₽ возвращено. Лицензия не предоставлена.'
  );
  IF v_updated = v_original THEN
    RAISE EXCEPTION 'Expected rejected Marketplace notification wording was not found';
  END IF;
  EXECUTE v_updated;
END;
$$;
