CREATE TABLE public.max_chat_profiles (
  max_id text PRIMARY KEY,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE
);
ALTER TABLE public.max_chat_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.max_chat_profiles FROM PUBLIC, anon, authenticated;

ALTER TABLE public.max_chat_accounts ADD COLUMN active boolean NOT NULL DEFAULT true;
ALTER TABLE public.max_chat_challenges ADD COLUMN signup_code_hash text;

CREATE FUNCTION public.reserve_lyrics_generation(
  p_id uuid, p_user_id uuid, p_prompt text, p_callback_token uuid, p_expected_price integer DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  existing public.lyrics_generation_jobs%ROWTYPE;
  quoted_price integer;
  billed record;
  log_id uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('lyrics:' || p_id::text, 0));
  SELECT * INTO existing FROM public.lyrics_generation_jobs WHERE id = p_id;
  IF FOUND THEN
    IF existing.user_id <> p_user_id OR existing.prompt <> p_prompt THEN
      RAISE EXCEPTION 'Lyrics request conflict';
    END IF;
    RETURN false;
  END IF;

  IF p_expected_price IS NOT NULL THEN
    SELECT price_rub INTO quoted_price FROM public.addon_services
    WHERE name = 'generate_lyrics' AND is_active LIMIT 1 FOR SHARE;
    IF quoted_price IS DISTINCT FROM p_expected_price THEN
      RAISE EXCEPTION 'Lyrics price changed';
    END IF;
  END IF;

  SELECT * INTO STRICT billed FROM public.debit_addon_service(
    p_user_id, 'generate_lyrics', 'Создание текста песни с AI',
    jsonb_build_object('request_id', p_id)
  );
  INSERT INTO public.generation_logs (
    user_id, request_id, service_id, service_name, provider, provider_operation, model, prompt,
    status, cost_rub, sale_price_rub, base_cost_credits, generation_params
  ) VALUES (
    p_user_id, p_id, billed.service_id, 'generate_lyrics', COALESCE(billed.provider, 'music_ai'),
    COALESCE(billed.provider_operation, 'generate_lyrics'), 'lyrics-ai', p_prompt, 'pending',
    billed.amount_debited, billed.amount_debited, billed.base_cost_credits,
    jsonb_build_object('prompt_length', length(p_prompt))
  ) RETURNING id INTO log_id;
  INSERT INTO public.lyrics_generation_jobs (id, user_id, prompt, callback_token, generation_log_id)
  VALUES (p_id, p_user_id, p_prompt, p_callback_token, log_id);
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.reserve_lyrics_generation(uuid, uuid, text, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_lyrics_generation(uuid, uuid, text, uuid, integer) TO service_role;
