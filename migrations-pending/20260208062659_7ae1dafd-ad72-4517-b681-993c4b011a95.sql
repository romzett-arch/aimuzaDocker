
-- Add AI analysis fields to forum_reports for hybrid moderation system
ALTER TABLE public.forum_reports
  ADD COLUMN IF NOT EXISTS ai_verdict TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_confidence NUMERIC(3,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_category TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ai_reason TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS content_snapshot TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS target_user_id UUID DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS auto_actioned BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS report_count INTEGER DEFAULT 1;

-- Index for fast pending + priority queries
CREATE INDEX IF NOT EXISTS idx_forum_reports_status_verdict 
  ON public.forum_reports (status, ai_verdict, created_at DESC);

-- Index for counting reports per target
CREATE INDEX IF NOT EXISTS idx_forum_reports_target 
  ON public.forum_reports (post_id, topic_id, status);

-- Function to count reports for the same target and update report_count
CREATE OR REPLACE FUNCTION public.forum_update_report_count()
RETURNS TRIGGER AS $$
BEGIN
  -- Update report_count for all pending reports on the same target
  IF NEW.post_id IS NOT NULL THEN
    UPDATE public.forum_reports
    SET report_count = (
      SELECT COUNT(*) FROM public.forum_reports 
      WHERE post_id = NEW.post_id AND status = 'pending'
    )
    WHERE post_id = NEW.post_id AND status = 'pending';
  ELSIF NEW.topic_id IS NOT NULL THEN
    UPDATE public.forum_reports
    SET report_count = (
      SELECT COUNT(*) FROM public.forum_reports 
      WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending'
    )
    WHERE topic_id = NEW.topic_id AND post_id IS NULL AND status = 'pending';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger to auto-update report counts
DROP TRIGGER IF EXISTS trg_forum_report_count ON public.forum_reports;
CREATE TRIGGER trg_forum_report_count
  AFTER INSERT ON public.forum_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_update_report_count();
