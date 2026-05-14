CREATE TABLE IF NOT EXISTS public.silk_releases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_track_id uuid REFERENCES public.tracks(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (
    status IN (
      'draft',
      'ready',
      'submitted',
      'needs_changes',
      'voting',
      'approved',
      'sent_to_silk',
      'live',
      'rejected',
      'archived'
    )
  ),
  title text NOT NULL DEFAULT '',
  version text,
  artist_name text NOT NULL DEFAULT '',
  featured_artists text,
  label_name text,
  genre text,
  subgenre text,
  language text DEFAULT 'ru',
  release_date date,
  original_release_date date,
  explicit_content boolean NOT NULL DEFAULT false,
  music_author text NOT NULL DEFAULT '',
  lyrics_author text NOT NULL DEFAULT '',
  producer_name text,
  copyright_holder text,
  phonogram_holder text,
  isrc_code text,
  upc_code text,
  platforms text[] NOT NULL DEFAULT ARRAY['Музыкальный лейбл Нота-Фея']::text[],
  territory text NOT NULL DEFAULT 'WORLD',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  admin_note text,
  user_note text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  sent_to_silk_at timestamptz,
  live_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.silk_release_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL REFERENCES public.silk_releases(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  asset_type text NOT NULL CHECK (
    asset_type IN (
      'master_wav',
      'reference_mp3',
      'cover_art',
      'package_zip',
      'lyrics',
      'license_document',
      'silk_export',
      'admin_attachment'
    )
  ),
  file_name text NOT NULL,
  storage_bucket text NOT NULL DEFAULT 'tracks',
  storage_path text NOT NULL,
  public_url text,
  content_type text,
  file_size bigint,
  checksum text,
  validation_status text NOT NULL DEFAULT 'pending' CHECK (
    validation_status IN ('pending', 'valid', 'invalid')
  ),
  validation_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (release_id, asset_type)
);

CREATE TABLE IF NOT EXISTS public.silk_release_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL REFERENCES public.silk_releases(id) ON DELETE CASCADE,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  from_status text,
  to_status text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.silk_release_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL REFERENCES public.silk_releases(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  is_admin_note boolean NOT NULL DEFAULT false,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.silk_royalty_statements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  period_start date NOT NULL,
  period_end date NOT NULL,
  currency text NOT NULL DEFAULT 'RUB',
  gross_amount numeric(12, 2) NOT NULL DEFAULT 0,
  net_amount numeric(12, 2) NOT NULL DEFAULT 0,
  source_file_url text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.silk_royalty_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement_id uuid NOT NULL REFERENCES public.silk_royalty_statements(id) ON DELETE CASCADE,
  release_id uuid REFERENCES public.silk_releases(id) ON DELETE SET NULL,
  track_title text NOT NULL,
  platform text,
  territory text,
  streams bigint NOT NULL DEFAULT 0,
  amount numeric(12, 2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_silk_releases_user_status ON public.silk_releases(user_id, status);
CREATE INDEX IF NOT EXISTS idx_silk_releases_status_submitted ON public.silk_releases(status, submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_silk_release_assets_release ON public.silk_release_assets(release_id);
CREATE INDEX IF NOT EXISTS idx_silk_release_events_release ON public.silk_release_events(release_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_silk_royalty_statements_user_period ON public.silk_royalty_statements(user_id, period_start DESC);

ALTER TABLE public.silk_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.silk_release_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.silk_release_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.silk_release_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.silk_royalty_statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.silk_royalty_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own silk releases" ON public.silk_releases;
CREATE POLICY "Users can view own silk releases"
ON public.silk_releases FOR SELECT
USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can create own silk releases" ON public.silk_releases;
CREATE POLICY "Users can create own silk releases"
ON public.silk_releases FOR INSERT
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update editable own silk releases" ON public.silk_releases;
CREATE POLICY "Users can update editable own silk releases"
ON public.silk_releases FOR UPDATE
USING (auth.uid() = user_id AND status IN ('draft', 'ready', 'needs_changes'))
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can manage silk releases" ON public.silk_releases;
CREATE POLICY "Admins can manage silk releases"
ON public.silk_releases FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view own silk assets" ON public.silk_release_assets;
CREATE POLICY "Users can view own silk assets"
ON public.silk_release_assets FOR SELECT
USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can manage editable own silk assets" ON public.silk_release_assets;
CREATE POLICY "Users can manage editable own silk assets"
ON public.silk_release_assets FOR ALL
USING (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes')
  )
)
WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes')
  )
);

DROP POLICY IF EXISTS "Admins can manage silk assets" ON public.silk_release_assets;
CREATE POLICY "Admins can manage silk assets"
ON public.silk_release_assets FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view own silk events" ON public.silk_release_events;
CREATE POLICY "Users can view own silk events"
ON public.silk_release_events FOR SELECT
USING (
  public.is_admin(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_events.release_id
      AND r.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can create own silk events" ON public.silk_release_events;
CREATE POLICY "Users can create own silk events"
ON public.silk_release_events FOR INSERT
WITH CHECK (
  actor_id = auth.uid()
  AND (
    public.is_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.silk_releases r
      WHERE r.id = silk_release_events.release_id
        AND r.user_id = auth.uid()
    )
  )
);

DROP POLICY IF EXISTS "Users can view own silk comments" ON public.silk_release_comments;
CREATE POLICY "Users can view own silk comments"
ON public.silk_release_comments FOR SELECT
USING (
  public.is_admin(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_comments.release_id
      AND r.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can create own silk comments" ON public.silk_release_comments;
CREATE POLICY "Users can create own silk comments"
ON public.silk_release_comments FOR INSERT
WITH CHECK (
  author_id = auth.uid()
  AND (
    public.is_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.silk_releases r
      WHERE r.id = silk_release_comments.release_id
        AND r.user_id = auth.uid()
    )
  )
);

DROP POLICY IF EXISTS "Users can view own silk royalty statements" ON public.silk_royalty_statements;
CREATE POLICY "Users can view own silk royalty statements"
ON public.silk_royalty_statements FOR SELECT
USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can manage silk royalty statements" ON public.silk_royalty_statements;
CREATE POLICY "Admins can manage silk royalty statements"
ON public.silk_royalty_statements FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view own silk royalty lines" ON public.silk_royalty_lines;
CREATE POLICY "Users can view own silk royalty lines"
ON public.silk_royalty_lines FOR SELECT
USING (
  public.is_admin(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.silk_royalty_statements s
    WHERE s.id = silk_royalty_lines.statement_id
      AND s.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Admins can manage silk royalty lines" ON public.silk_royalty_lines;
CREATE POLICY "Admins can manage silk royalty lines"
ON public.silk_royalty_lines FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

DROP TRIGGER IF EXISTS update_silk_releases_updated_at ON public.silk_releases;
CREATE TRIGGER update_silk_releases_updated_at
BEFORE UPDATE ON public.silk_releases
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_silk_release_assets_updated_at ON public.silk_release_assets;
CREATE TRIGGER update_silk_release_assets_updated_at
BEFORE UPDATE ON public.silk_release_assets
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

GRANT SELECT, INSERT, UPDATE, DELETE ON public.silk_releases TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.silk_release_assets TO authenticated;
GRANT SELECT, INSERT ON public.silk_release_events TO authenticated;
GRANT SELECT, INSERT ON public.silk_release_comments TO authenticated;
GRANT SELECT ON public.silk_royalty_statements TO authenticated;
GRANT SELECT ON public.silk_royalty_lines TO authenticated;
