
-- Create legal_documents table for editable legal/policy pages
CREATE TABLE public.legal_documents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  content_html TEXT NOT NULL DEFAULT '',
  icon TEXT DEFAULT 'FileText',
  is_published BOOLEAN NOT NULL DEFAULT true,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;

-- Public can read published documents
CREATE POLICY "Anyone can read published legal documents"
ON public.legal_documents FOR SELECT
USING (is_published = true);

-- Admins can manage documents
CREATE POLICY "Admins can manage legal documents"
ON public.legal_documents FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Seed initial documents
INSERT INTO public.legal_documents (slug, title, icon) VALUES
  ('terms', 'Пользовательское соглашение', 'FileText'),
  ('offer', 'Публичная оферта', 'Briefcase'),
  ('audit-policy', 'Регламент технического аудита', 'Shield'),
  ('distribution-requirements', 'Требования к дистрибуции', 'Music');
