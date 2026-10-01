CREATE OR REPLACE FUNCTION public.enforce_song_idea_brief_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_limit INTEGER;
BEGIN
  SELECT brief_char_limit INTO v_limit FROM public.song_idea_settings WHERE singleton = true;
  IF char_length(NEW.generator_brief) > COALESCE(v_limit, 1000) THEN
    RAISE EXCEPTION 'Короткий бриф превышает лимит в % символов', COALESCE(v_limit, 1000);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_song_idea_brief_limit ON public.song_ideas;
CREATE TRIGGER trg_song_idea_brief_limit BEFORE INSERT OR UPDATE OF generator_brief ON public.song_ideas FOR EACH ROW EXECUTE FUNCTION public.enforce_song_idea_brief_limit();
