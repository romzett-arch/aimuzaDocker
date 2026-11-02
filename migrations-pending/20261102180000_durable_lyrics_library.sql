-- Texts outlive audio generation and track deletion. Jobs are server-owned.
CREATE TABLE IF NOT EXISTS public.lyrics_generation_jobs (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  prompt text NOT NULL,
  callback_token uuid NOT NULL DEFAULT gen_random_uuid(),
  provider_task_id text,
  generation_log_id uuid REFERENCES public.generation_logs(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','failed')),
  last_polled_at timestamptz,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lyrics_generation_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lyrics_generation_jobs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.lyrics_generation_jobs TO service_role;
CREATE INDEX IF NOT EXISTS lyrics_jobs_pending ON public.lyrics_generation_jobs(last_polled_at NULLS FIRST) WHERE status = 'pending';

ALTER TABLE public.generated_lyrics ADD COLUMN IF NOT EXISTS job_id uuid REFERENCES public.lyrics_generation_jobs(id) ON DELETE SET NULL;
ALTER TABLE public.generated_lyrics ADD COLUMN IF NOT EXISTS variant_key text;
CREATE UNIQUE INDEX IF NOT EXISTS generated_lyrics_job_variant ON public.generated_lyrics(job_id, variant_key);
CREATE INDEX IF NOT EXISTS generated_lyrics_content_lookup ON public.generated_lyrics(user_id, md5(lyrics));
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS generated_lyrics_id uuid REFERENCES public.generated_lyrics(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.complete_lyrics_job(p_job_id uuid, p_results jsonb)
RETURNS SETOF public.generated_lyrics
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.lyrics_generation_jobs; item jsonb;
BEGIN
  SELECT * INTO STRICT j FROM public.lyrics_generation_jobs WHERE id = p_job_id FOR UPDATE;
  IF jsonb_typeof(p_results) <> 'array' OR jsonb_array_length(p_results) = 0 THEN
    RAISE EXCEPTION 'No lyrics results';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_results) LOOP
    IF length(btrim(COALESCE(item->>'text',''))) = 0 THEN RAISE EXCEPTION 'Empty lyrics'; END IF;
    INSERT INTO public.generated_lyrics(user_id,prompt,lyrics,title,job_id,variant_key)
    VALUES(j.user_id,j.prompt,item->>'text',NULLIF(item->>'title',''),j.id,item->>'key')
    ON CONFLICT (job_id,variant_key) DO NOTHING;
  END LOOP;
  UPDATE public.lyrics_generation_jobs SET status='completed',error_message=NULL WHERE id=j.id;
  UPDATE public.generation_logs SET status='completed',error_message=NULL,
    metadata=COALESCE(metadata,'{}'::jsonb) || jsonb_build_object('task_id',j.provider_task_id,'lyrics_job_id',j.id)
    WHERE id=j.generation_log_id;
  RETURN QUERY SELECT * FROM public.generated_lyrics WHERE job_id=j.id ORDER BY variant_key;
END $$;
REVOKE ALL ON FUNCTION public.complete_lyrics_job(uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_lyrics_job(uuid,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.fail_lyrics_job(p_job_id uuid, p_error text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.lyrics_generation_jobs; amount integer;
BEGIN
  SELECT * INTO STRICT j FROM public.lyrics_generation_jobs WHERE id=p_job_id FOR UPDATE;
  IF j.status <> 'pending' THEN RETURN; END IF;
  SELECT COALESCE(sale_price_rub,cost_rub,0)::integer INTO amount FROM public.generation_logs WHERE id=j.generation_log_id;
  IF amount > 0 THEN
    PERFORM public.refund_addon_service(j.user_id,amount,'Возврат за неуспешное создание текста',jsonb_build_object('request_id',j.id,'service_name','generate_lyrics'));
  END IF;
  UPDATE public.lyrics_generation_jobs SET status='failed',error_message=p_error WHERE id=j.id;
  UPDATE public.generation_logs SET status='failed',error_message=p_error,refund_rub=COALESCE(amount,0) WHERE id=j.generation_log_id;
END $$;
REVOKE ALL ON FUNCTION public.fail_lyrics_job(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_lyrics_job(uuid,text) TO service_role;

-- A snapshot is written in the SAME transaction as a track's lyrics. No audio
-- status/deletion can remove it. Identical text from the same author is reused.
CREATE OR REPLACE FUNCTION public.archive_track_lyrics()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE saved_id uuid;
BEGIN
  IF NEW.lyrics IS NULL OR btrim(NEW.lyrics) = '' THEN NEW.generated_lyrics_id=NULL; RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::text || NEW.lyrics,0));
  SELECT id INTO saved_id FROM public.generated_lyrics
    WHERE user_id=NEW.user_id AND md5(lyrics)=md5(NEW.lyrics) AND lyrics=NEW.lyrics ORDER BY created_at,id LIMIT 1;
  IF saved_id IS NULL THEN
    INSERT INTO public.generated_lyrics(user_id,prompt,lyrics,title)
      VALUES(NEW.user_id,COALESCE(NEW.description,''),NEW.lyrics,NEW.title) RETURNING id INTO saved_id;
  END IF;
  NEW.generated_lyrics_id=saved_id;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER archive_track_lyrics
  BEFORE INSERT OR UPDATE OF lyrics ON public.tracks
  FOR EACH ROW EXECUTE FUNCTION public.archive_track_lyrics();
UPDATE public.tracks SET lyrics=lyrics WHERE lyrics IS NOT NULL AND btrim(lyrics)<>'' AND generated_lyrics_id IS NULL;
