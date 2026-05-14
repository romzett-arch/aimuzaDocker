CREATE TABLE IF NOT EXISTS public.silk_release_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL REFERENCES public.silk_releases(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  request_type text NOT NULL CHECK (request_type IN ('editing', 'deletion')),
  message text NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'declined')),
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_silk_release_requests_release
ON public.silk_release_requests(release_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_silk_release_requests_open
ON public.silk_release_requests(status, created_at DESC)
WHERE status = 'open';

ALTER TABLE public.silk_release_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own silk release requests" ON public.silk_release_requests;
CREATE POLICY "Users can view own silk release requests"
ON public.silk_release_requests FOR SELECT
USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can create own silk release requests" ON public.silk_release_requests;
CREATE POLICY "Users can create own silk release requests"
ON public.silk_release_requests FOR INSERT
WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1 FROM public.silk_releases r
    WHERE r.id = silk_release_requests.release_id
      AND r.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Admins can manage silk release requests" ON public.silk_release_requests;
CREATE POLICY "Admins can manage silk release requests"
ON public.silk_release_requests FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.silk_release_requests TO authenticated;
