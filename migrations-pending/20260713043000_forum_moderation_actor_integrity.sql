-- Prevent staff clients from attributing moderation actions to another actor.

DROP POLICY IF EXISTS "Mods create warnings" ON public.forum_warnings;
CREATE POLICY "Mods create warnings"
  ON public.forum_warnings FOR INSERT
  WITH CHECK (
    issued_by = auth.uid()
    AND (
      public.has_role(auth.uid(), 'moderator')
      OR public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'super_admin')
    )
  );

DROP POLICY IF EXISTS "Moderators can manage bans" ON public.forum_user_bans;
CREATE POLICY "Moderators can manage bans"
  ON public.forum_user_bans FOR INSERT
  WITH CHECK (
    banned_by = auth.uid()
    AND (
      public.has_role(auth.uid(), 'moderator')
      OR public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'super_admin')
    )
  );

DROP POLICY IF EXISTS "Forum staff manage warning points" ON public.forum_warning_points;
DROP POLICY IF EXISTS "Forum staff create warning points" ON public.forum_warning_points;
CREATE POLICY "Forum staff create warning points"
  ON public.forum_warning_points FOR INSERT
  WITH CHECK (
    issued_by = auth.uid()
    AND (
      public.has_role(auth.uid(), 'moderator')
      OR public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'super_admin')
    )
  );

DROP POLICY IF EXISTS "Forum staff update warning points" ON public.forum_warning_points;
CREATE POLICY "Forum staff update warning points"
  ON public.forum_warning_points FOR UPDATE
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Forum staff delete warning points" ON public.forum_warning_points;
CREATE POLICY "Forum staff delete warning points"
  ON public.forum_warning_points FOR DELETE
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );
