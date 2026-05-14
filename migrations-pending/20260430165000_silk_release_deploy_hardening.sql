DROP FUNCTION IF EXISTS public.request_silk_release_action(uuid, text, text);

ALTER TABLE public.silk_releases
  DROP COLUMN IF EXISTS user_request_type,
  DROP COLUMN IF EXISTS user_request_message,
  DROP COLUMN IF EXISTS user_request_status,
  DROP COLUMN IF EXISTS user_request_at,
  DROP COLUMN IF EXISTS user_request_resolved_at;

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (PARTITION BY release_id ORDER BY created_at DESC, id DESC) AS rn
  FROM public.silk_release_requests
  WHERE status = 'open'
)
UPDATE public.silk_release_requests r
SET
  status = 'declined',
  admin_note = COALESCE(r.admin_note, 'Автоматически закрыт как дубликат открытого запроса'),
  resolved_at = COALESCE(r.resolved_at, now())
FROM ranked
WHERE r.id = ranked.id
  AND ranked.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_silk_release_requests_open_per_release
ON public.silk_release_requests(release_id)
WHERE status = 'open';

DROP POLICY IF EXISTS "Users can update editable own silk releases" ON public.silk_releases;
CREATE POLICY "Users can update editable own silk releases"
ON public.silk_releases FOR UPDATE
USING (
  auth.uid() = user_id
  AND status IN ('draft', 'ready', 'needs_changes', 'rejected')
)
WITH CHECK (
  auth.uid() = user_id
  AND user_id = auth.uid()
  AND status IN ('draft', 'ready', 'needs_changes', 'rejected', 'submitted')
);

DROP POLICY IF EXISTS "Users can create own silk releases" ON public.silk_releases;
CREATE POLICY "Users can create own silk releases"
ON public.silk_releases FOR INSERT
WITH CHECK (
  auth.uid() = user_id
  AND status IN ('draft', 'ready')
);

DROP POLICY IF EXISTS "Users can manage editable own silk assets" ON public.silk_release_assets;
CREATE POLICY "Users can manage editable own silk assets"
ON public.silk_release_assets FOR ALL
USING (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes', 'rejected')
  )
)
WITH CHECK (
  auth.uid() = user_id
  AND user_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_assets.release_id
      AND r.user_id = auth.uid()
      AND r.status IN ('draft', 'ready', 'needs_changes', 'rejected')
  )
);

DROP POLICY IF EXISTS "Users can create own silk release requests" ON public.silk_release_requests;
CREATE POLICY "Users can create own silk release requests"
ON public.silk_release_requests FOR INSERT
WITH CHECK (
  auth.uid() = user_id
  AND status = 'open'
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_requests.release_id
      AND r.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can create own silk comments" ON public.silk_release_comments;
CREATE POLICY "Users can create own silk comments"
ON public.silk_release_comments FOR INSERT
WITH CHECK (
  author_id = auth.uid()
  AND is_admin_note = false
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_comments.release_id
      AND r.user_id = auth.uid()
  )
);
