-- Reconcile legacy and current legal_documents contracts without deleting data.
CREATE TABLE IF NOT EXISTS public.legal_documents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slug TEXT,
  title TEXT NOT NULL,
  content_html TEXT,
  icon TEXT,
  is_published BOOLEAN,
  updated_at TIMESTAMPTZ,
  updated_by UUID,
  created_at TIMESTAMPTZ
);

ALTER TABLE public.legal_documents
  ADD COLUMN IF NOT EXISTS slug TEXT,
  ADD COLUMN IF NOT EXISTS content_html TEXT,
  ADD COLUMN IF NOT EXISTS icon TEXT,
  ADD COLUMN IF NOT EXISTS is_published BOOLEAN,
  ADD COLUMN IF NOT EXISTS updated_by UUID;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'legal_documents' AND column_name = 'type'
  ) THEN
    EXECUTE $sql$
      UPDATE public.legal_documents
      SET slug = COALESCE(NULLIF(slug, ''), NULLIF(type, ''), 'document-' || id::text)
      WHERE slug IS NULL OR slug = ''
    $sql$;
    EXECUTE 'ALTER TABLE public.legal_documents ALTER COLUMN type DROP NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'legal_documents' AND column_name = 'content'
  ) THEN
    EXECUTE $sql$
      UPDATE public.legal_documents
      SET content_html = COALESCE(content_html, content, '')
      WHERE content_html IS NULL
    $sql$;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'legal_documents' AND column_name = 'is_active'
  ) THEN
    EXECUTE $sql$
      UPDATE public.legal_documents
      SET is_published = COALESCE(is_published, is_active, true)
      WHERE is_published IS NULL
    $sql$;
  END IF;
END
$$;

UPDATE public.legal_documents
SET slug = 'document-' || id::text
WHERE slug IS NULL OR slug = '';

WITH duplicate_slugs AS (
  SELECT id, slug, row_number() OVER (PARTITION BY slug ORDER BY created_at NULLS LAST, id) AS position
  FROM public.legal_documents
)
UPDATE public.legal_documents AS documents
SET slug = documents.slug || '-' || left(documents.id::text, 8)
FROM duplicate_slugs
WHERE documents.id = duplicate_slugs.id AND duplicate_slugs.position > 1;

UPDATE public.legal_documents
SET content_html = COALESCE(content_html, ''),
    icon = COALESCE(icon, 'FileText'),
    is_published = COALESCE(is_published, true),
    created_at = COALESCE(created_at, now()),
    updated_at = COALESCE(updated_at, now());

ALTER TABLE public.legal_documents
  ALTER COLUMN slug SET NOT NULL,
  ALTER COLUMN content_html SET DEFAULT '',
  ALTER COLUMN content_html SET NOT NULL,
  ALTER COLUMN icon SET DEFAULT 'FileText',
  ALTER COLUMN is_published SET DEFAULT true,
  ALTER COLUMN is_published SET NOT NULL,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS legal_documents_slug_key
  ON public.legal_documents (slug);

ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'legal_documents'
      AND policyname = 'Anyone can read published legal documents'
  ) THEN
    CREATE POLICY "Anyone can read published legal documents"
      ON public.legal_documents FOR SELECT
      USING (is_published = true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'legal_documents'
      AND policyname = 'Admins can manage legal documents v2'
  ) THEN
    CREATE POLICY "Admins can manage legal documents v2"
      ON public.legal_documents FOR ALL
      TO authenticated
      USING (public.is_admin(auth.uid()))
      WITH CHECK (public.is_admin(auth.uid()));
  END IF;
END
$$;

INSERT INTO public.legal_documents (slug, title, icon)
VALUES
  ('terms', 'Пользовательское соглашение', 'FileText'),
  ('offer', 'Публичная оферта', 'Briefcase'),
  ('audit-policy', 'Регламент технического аудита', 'Shield'),
  ('distribution-requirements', 'Требования к дистрибуции', 'Music')
ON CONFLICT (slug) DO NOTHING;
