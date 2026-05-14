
-- ============================================
-- Admin Announcements System
-- ============================================

-- Enum for announcement types
CREATE TYPE public.announcement_type AS ENUM ('system', 'news', 'event', 'community');

-- Enum for display mode
CREATE TYPE public.announcement_display_mode AS ENUM ('banner', 'modal');

-- Enum for priority
CREATE TYPE public.announcement_priority AS ENUM ('info', 'warning', 'critical');

-- Main announcements table
CREATE TABLE public.admin_announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  content_html TEXT,
  announcement_type public.announcement_type NOT NULL DEFAULT 'news',
  display_mode public.announcement_display_mode NOT NULL DEFAULT 'banner',
  priority public.announcement_priority NOT NULL DEFAULT 'info',
  is_dismissible BOOLEAN NOT NULL DEFAULT true,
  is_published BOOLEAN NOT NULL DEFAULT false,
  publish_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  target_audience JSONB DEFAULT NULL,
  cover_url TEXT,
  action_url TEXT,
  action_label TEXT,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Dismissals tracking
CREATE TABLE public.announcement_dismissals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id UUID NOT NULL REFERENCES public.admin_announcements(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(announcement_id, user_id)
);

-- Indexes
CREATE INDEX idx_announcements_published ON public.admin_announcements (is_published, publish_at, expires_at);
CREATE INDEX idx_announcements_type ON public.admin_announcements (announcement_type);
CREATE INDEX idx_dismissals_user ON public.announcement_dismissals (user_id);
CREATE INDEX idx_dismissals_announcement ON public.announcement_dismissals (announcement_id);

-- Enable RLS
ALTER TABLE public.admin_announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcement_dismissals ENABLE ROW LEVEL SECURITY;

-- Announcements: everyone can read published
CREATE POLICY "Anyone can read published announcements"
  ON public.admin_announcements FOR SELECT
  USING (is_published = true);

-- Announcements: admins can do everything
CREATE POLICY "Admins can manage announcements"
  ON public.admin_announcements FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Dismissals: users can read their own
CREATE POLICY "Users can read own dismissals"
  ON public.announcement_dismissals FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Dismissals: users can insert their own
CREATE POLICY "Users can dismiss announcements"
  ON public.announcement_dismissals FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Updated_at trigger
CREATE TRIGGER update_announcements_updated_at
  BEFORE UPDATE ON public.admin_announcements
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================
-- Welcome onboarding tracking
-- ============================================
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN DEFAULT false;
