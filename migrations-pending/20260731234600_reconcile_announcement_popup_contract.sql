-- Reconcile legacy announcement tables with the current popup contract.
DO $types$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'announcement_type' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.announcement_type AS ENUM ('system', 'news', 'event', 'community');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'announcement_display_mode' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.announcement_display_mode AS ENUM ('banner', 'modal');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'announcement_priority' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.announcement_priority AS ENUM ('info', 'warning', 'critical');
  END IF;
END
$types$;

ALTER TABLE public.admin_announcements
  ADD COLUMN IF NOT EXISTS content_html text,
  ADD COLUMN IF NOT EXISTS announcement_type public.announcement_type DEFAULT 'news',
  ADD COLUMN IF NOT EXISTS display_mode public.announcement_display_mode DEFAULT 'banner',
  ADD COLUMN IF NOT EXISTS priority public.announcement_priority DEFAULT 'info',
  ADD COLUMN IF NOT EXISTS is_dismissible boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS cover_url text,
  ADD COLUMN IF NOT EXISTS action_url text,
  ADD COLUMN IF NOT EXISTS action_label text,
  ADD COLUMN IF NOT EXISTS created_by uuid;

UPDATE public.admin_announcements
SET announcement_type = COALESCE(announcement_type, 'news'),
    display_mode = COALESCE(display_mode, 'banner'),
    priority = COALESCE(priority, 'info'),
    is_dismissible = COALESCE(is_dismissible, true);

