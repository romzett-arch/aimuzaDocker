BEGIN;

ALTER TABLE public.track_health_reports
  ADD COLUMN IF NOT EXISTS quality_score integer,
  ADD COLUMN IF NOT EXISTS lufs_original numeric(6,2),
  ADD COLUMN IF NOT EXISTS lufs_normalized numeric(6,2),
  ADD COLUMN IF NOT EXISTS peak_db numeric(6,2),
  ADD COLUMN IF NOT EXISTS dynamic_range numeric(6,2),
  ADD COLUMN IF NOT EXISTS spectrum_ok boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS high_freq_cutoff integer,
  ADD COLUMN IF NOT EXISTS upscale_detected boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS sample_rate integer,
  ADD COLUMN IF NOT EXISTS bit_depth integer,
  ADD COLUMN IF NOT EXISTS channels integer,
  ADD COLUMN IF NOT EXISTS duration numeric(10,2),
  ADD COLUMN IF NOT EXISTS format text,
  ADD COLUMN IF NOT EXISTS master_quality boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS recommendations text[],
  ADD COLUMN IF NOT EXISTS plagiarism_percent numeric(5,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS plagiarism_matches jsonb,
  ADD COLUMN IF NOT EXISTS plagiarism_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS analysis_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS normalization_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS normalized_audio_url text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.track_health_reports
SET analysis_status = CASE
  WHEN status IN ('ok', 'completed') THEN 'completed'
  WHEN status IN ('failed', 'error') THEN 'failed'
  ELSE 'pending'
END
WHERE analysis_status IS NULL OR analysis_status = 'pending';

DELETE FROM public.track_health_reports WHERE track_id IS NULL;
DELETE FROM public.track_health_reports older
USING public.track_health_reports newer
WHERE older.track_id = newer.track_id
  AND (older.created_at, older.id) < (newer.created_at, newer.id);

ALTER TABLE public.track_health_reports ALTER COLUMN track_id SET NOT NULL;
ALTER TABLE public.track_health_reports DROP CONSTRAINT IF EXISTS track_health_reports_quality_score_check;
ALTER TABLE public.track_health_reports ADD CONSTRAINT track_health_reports_quality_score_check
  CHECK (quality_score IS NULL OR quality_score BETWEEN 1 AND 10);
ALTER TABLE public.track_health_reports DROP CONSTRAINT IF EXISTS track_health_reports_analysis_status_check;
ALTER TABLE public.track_health_reports ADD CONSTRAINT track_health_reports_analysis_status_check
  CHECK (analysis_status IN ('pending','analyzing','completed','failed'));
ALTER TABLE public.track_health_reports DROP CONSTRAINT IF EXISTS track_health_reports_normalization_status_check;
ALTER TABLE public.track_health_reports ADD CONSTRAINT track_health_reports_normalization_status_check
  CHECK (normalization_status IN ('pending','processing','completed','skipped','failed'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_track_health_reports_track_id
  ON public.track_health_reports(track_id);

DROP TRIGGER IF EXISTS update_track_health_reports_updated_at ON public.track_health_reports;
CREATE TRIGGER update_track_health_reports_updated_at
  BEFORE UPDATE ON public.track_health_reports
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMIT;
