-- Defense-in-depth RLS for forum moderation data. The Node REST layer mirrors
-- these rules because its owner connection bypasses RLS.

ALTER TABLE public.forum_mod_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_staff_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_warning_appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_warning_points ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read automod settings" ON public.forum_automod_settings;
DROP POLICY IF EXISTS "Forum staff read automod settings" ON public.forum_automod_settings;
CREATE POLICY "Forum staff read automod settings"
  ON public.forum_automod_settings FOR SELECT
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Forum staff manage mod logs" ON public.forum_mod_logs;
CREATE POLICY "Forum staff manage mod logs"
  ON public.forum_mod_logs FOR ALL
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    moderator_id = auth.uid()
    AND (
      public.has_role(auth.uid(), 'moderator')
      OR public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'super_admin')
    )
  );

DROP POLICY IF EXISTS "Forum staff manage staff notes" ON public.forum_staff_notes;
CREATE POLICY "Forum staff manage staff notes"
  ON public.forum_staff_notes FOR ALL
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    author_id = auth.uid()
    AND (
      public.has_role(auth.uid(), 'moderator')
      OR public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'super_admin')
    )
  );

DROP POLICY IF EXISTS "Users create forum reports" ON public.forum_reports;
CREATE POLICY "Users create forum reports"
  ON public.forum_reports FOR INSERT WITH CHECK (reporter_id = auth.uid());
DROP POLICY IF EXISTS "Users and staff read forum reports" ON public.forum_reports;
CREATE POLICY "Users and staff read forum reports"
  ON public.forum_reports FOR SELECT
  USING (
    reporter_id = auth.uid()
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );
DROP POLICY IF EXISTS "Forum staff update reports" ON public.forum_reports;
CREATE POLICY "Forum staff update reports"
  ON public.forum_reports FOR UPDATE
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Users create own warning appeals" ON public.forum_warning_appeals;
CREATE POLICY "Users create own warning appeals"
  ON public.forum_warning_appeals FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS "Users and staff read warning appeals" ON public.forum_warning_appeals;
CREATE POLICY "Users and staff read warning appeals"
  ON public.forum_warning_appeals FOR SELECT
  USING (
    user_id = auth.uid()
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );
DROP POLICY IF EXISTS "Forum staff review warning appeals" ON public.forum_warning_appeals;
CREATE POLICY "Forum staff review warning appeals"
  ON public.forum_warning_appeals FOR UPDATE
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Forum staff manage warning points" ON public.forum_warning_points;
CREATE POLICY "Forum staff manage warning points"
  ON public.forum_warning_points FOR ALL
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

GRANT SELECT, INSERT ON public.forum_reports TO authenticated;
GRANT UPDATE ON public.forum_reports TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.forum_warning_appeals TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.forum_mod_logs, public.forum_staff_notes, public.forum_warning_points TO authenticated;
