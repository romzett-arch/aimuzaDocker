-- A late AI callback must not restore private texts after account closure.
CREATE OR REPLACE FUNCTION public.guard_deleted_account_lyrics()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM auth.users WHERE id=NEW.user_id AND raw_user_meta_data->>'deleted_at' IS NOT NULL) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER guard_deleted_account_lyrics
  BEFORE INSERT ON public.generated_lyrics
  FOR EACH ROW EXECUTE FUNCTION public.guard_deleted_account_lyrics();
