
-- Add email_unsubscribed column to profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email_unsubscribed boolean NOT NULL DEFAULT false;

-- Table for admin sent emails log
CREATE TABLE public.admin_emails (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL,
  sender_type text NOT NULL DEFAULT 'project', -- 'personal' or 'project'
  recipient_id uuid, -- null for mass emails
  recipient_email text NOT NULL,
  subject text NOT NULL,
  body_html text NOT NULL,
  template_id uuid,
  status text NOT NULL DEFAULT 'sent', -- sent, failed, bounced
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_emails ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage admin_emails"
ON public.admin_emails FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Email templates table
CREATE TABLE public.email_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  subject text NOT NULL,
  body_html text NOT NULL,
  category text NOT NULL DEFAULT 'general', -- warning, ban, welcome, promo, general
  created_by uuid NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.email_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage email_templates"
ON public.email_templates FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));

-- Index for faster lookups
CREATE INDEX idx_admin_emails_sender ON public.admin_emails(sender_id);
CREATE INDEX idx_admin_emails_recipient ON public.admin_emails(recipient_id);
CREATE INDEX idx_admin_emails_created ON public.admin_emails(created_at DESC);
CREATE INDEX idx_profiles_unsubscribed ON public.profiles(email_unsubscribed) WHERE email_unsubscribed = true;
