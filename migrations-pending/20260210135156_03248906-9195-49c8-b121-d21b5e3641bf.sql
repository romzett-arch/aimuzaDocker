-- Allow automod system user to insert warnings
CREATE POLICY "System automod can insert warnings"
ON public.forum_warnings
FOR INSERT
WITH CHECK (issued_by = '00000000-0000-0000-0000-000000000000'::uuid);

-- Allow automod system user to insert mod logs
CREATE POLICY "System automod can insert logs"
ON public.forum_mod_logs
FOR INSERT
WITH CHECK (moderator_id = '00000000-0000-0000-0000-000000000000'::uuid);

-- Allow any authenticated user to update their own forum_user_stats warnings_count
-- (needed for automod to update warning count after inserting warning)
CREATE POLICY "System automod can update user stats warnings"
ON public.forum_user_stats
FOR UPDATE
USING (true)
WITH CHECK (true);