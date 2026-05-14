
-- Add missing columns to notifications table
-- These are needed by the forum_notify_warning trigger and are useful for all notifications
ALTER TABLE public.notifications 
ADD COLUMN IF NOT EXISTS link TEXT,
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT NULL,
ADD COLUMN IF NOT EXISTS data JSONB DEFAULT NULL;

UPDATE public.notifications
SET
  metadata = COALESCE(metadata, data),
  data = COALESCE(data, metadata)
WHERE metadata IS DISTINCT FROM COALESCE(metadata, data)
   OR data IS DISTINCT FROM COALESCE(data, metadata);

-- Add comment for documentation
COMMENT ON COLUMN public.notifications.link IS 'Navigation link for the notification (e.g. /forum, /track/123)';
COMMENT ON COLUMN public.notifications.metadata IS 'Additional structured data for the notification';
COMMENT ON COLUMN public.notifications.data IS 'Legacy alias for metadata used by older migrations/functions';
