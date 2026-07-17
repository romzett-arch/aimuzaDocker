DO $$
DECLARE
  v_original text;
  v_updated text;
BEGIN
  SELECT pg_get_functiondef(
    'public.record_lyrics_blockchain_deposit(uuid,uuid,uuid,text,text,text,text,text,timestamptz,text,text,integer)'::regprocedure
  ) INTO v_original;

  v_updated := replace(
    replace(
      v_original,
      '''Депонирование AIMUZA отправлено''',
      '''Цифровая метка создана'''
    ),
    '''Цифровой отпечаток текста «'' || p_work_title || ''» отправлен в OpenTimestamps. AIMUZA сохранила доказательство; ожидается подтверждение Bitcoin.''',
    '''AIMUZA зафиксировала версию текста «'' || p_work_title || ''» и сохранила проверяемое доказательство. Независимая проверка даты выполняется автоматически.'''
  );

  IF v_updated = v_original THEN
    RAISE EXCEPTION 'Expected lyrics deposit notification wording was not found';
  END IF;
  EXECUTE v_updated;
END;
$$;

UPDATE public.notifications n
SET title = 'Цифровая метка создана',
    message = 'AIMUZA зафиксировала версию текста и сохранила проверяемое доказательство. Независимая проверка даты выполняется автоматически.'
FROM public.lyrics_deposits ld
WHERE n.type = 'lyrics_deposited'
  AND n.target_type = 'lyrics'
  AND n.target_id = ld.lyrics_id
  AND ld.method = 'blockchain'
  AND ld.status IN ('pending', 'processing')
  AND n.title = 'Депонирование AIMUZA отправлено';
