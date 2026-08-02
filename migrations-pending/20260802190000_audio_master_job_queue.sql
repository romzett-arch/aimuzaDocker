CREATE TABLE IF NOT EXISTS public.audio_master_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL UNIQUE REFERENCES public.tracks(id) ON DELETE CASCADE,
  source_audio_url text NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'processing', 'completed', 'failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  run_after timestamptz NOT NULL DEFAULT now(),
  lease_until timestamptz,
  locked_by text,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_audio_master_jobs_ready
  ON public.audio_master_jobs (run_after, created_at)
  WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_audio_master_jobs_expired_lease
  ON public.audio_master_jobs (lease_until)
  WHERE status = 'processing';

ALTER TABLE public.audio_master_jobs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.audio_master_jobs FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.audio_master_jobs TO service_role;

CREATE OR REPLACE FUNCTION public.claim_track_audio_ingest(
  p_track_id uuid,
  p_suno_audio_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claimed uuid;
BEGIN
  UPDATE public.tracks
  SET processing_stage = 'saving_original',
      processing_progress = GREATEST(COALESCE(processing_progress, 0), 75),
      suno_audio_id = COALESCE(p_suno_audio_id, suno_audio_id),
      updated_at = now()
  WHERE id = p_track_id
    AND master_audio_url IS NULL
    AND status NOT IN ('completed', 'failed')
    AND (suno_audio_id IS NULL OR p_suno_audio_id IS NULL OR suno_audio_id = p_suno_audio_id)
    AND (
      processing_stage IS DISTINCT FROM 'saving_original'
      OR updated_at < now() - interval '5 minutes'
    )
  RETURNING id INTO v_claimed;

  RETURN v_claimed IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_track_audio_ingest(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_track_audio_ingest(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_audio_master_job(
  p_track_id uuid,
  p_source_audio_url text
)
RETURNS public.audio_master_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job public.audio_master_jobs;
BEGIN
  IF p_source_audio_url IS NULL OR btrim(p_source_audio_url) = '' THEN
    RAISE EXCEPTION 'source audio URL is required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tracks
    WHERE id = p_track_id AND master_audio_url IS NOT NULL
  ) THEN
    SELECT * INTO v_job
    FROM public.audio_master_jobs
    WHERE track_id = p_track_id;
    RETURN v_job;
  END IF;

  INSERT INTO public.audio_master_jobs (track_id, source_audio_url)
  VALUES (p_track_id, p_source_audio_url)
  ON CONFLICT (track_id) DO UPDATE
  SET source_audio_url = EXCLUDED.source_audio_url,
      status = CASE
        WHEN audio_master_jobs.status = 'failed' THEN 'queued'
        ELSE audio_master_jobs.status
      END,
      run_after = CASE
        WHEN audio_master_jobs.status = 'failed' THEN now()
        ELSE audio_master_jobs.run_after
      END,
      last_error = CASE
        WHEN audio_master_jobs.status = 'failed' THEN NULL
        ELSE audio_master_jobs.last_error
      END,
      updated_at = now()
  RETURNING * INTO v_job;

  UPDATE public.tracks
  SET processing_stage = CASE
        WHEN v_job.status = 'processing' THEN 'mastering'
        ELSE 'mastering_queued'
      END,
      processing_progress = GREATEST(COALESCE(processing_progress, 0), 85),
      updated_at = now()
  WHERE id = p_track_id
    AND master_audio_url IS NULL;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_audio_master_job(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_audio_master_job(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_audio_master_jobs(
  p_worker_id text,
  p_limit integer DEFAULT 1,
  p_lease_seconds integer DEFAULT 600
)
RETURNS SETOF public.audio_master_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION 'worker ID is required';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT job.id
    FROM public.audio_master_jobs AS job
    WHERE (
      job.status = 'queued' AND job.run_after <= now()
    ) OR (
      job.status = 'processing' AND job.lease_until < now()
    )
    ORDER BY job.run_after, job.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(GREATEST(p_limit, 1), 32)
  )
  UPDATE public.audio_master_jobs AS job
  SET status = 'processing',
      attempts = job.attempts + 1,
      locked_by = p_worker_id,
      lease_until = now() + make_interval(secs => LEAST(GREATEST(p_lease_seconds, 60), 3600)),
      updated_at = now()
  FROM candidates
  WHERE job.id = candidates.id
  RETURNING job.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_audio_master_jobs(text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_audio_master_jobs(text, integer, integer) TO service_role;

INSERT INTO public.audio_master_jobs (track_id, source_audio_url)
SELECT id, audio_url
FROM public.tracks
WHERE status = 'processing'
  AND master_audio_url IS NULL
  AND audio_url IS NOT NULL
  AND suno_audio_id IS NOT NULL
ON CONFLICT (track_id) DO NOTHING;

COMMENT ON TABLE public.audio_master_jobs IS
  'Durable, deduplicated queue for creating one playback master per generated track.';

NOTIFY pgrst, 'reload schema';
