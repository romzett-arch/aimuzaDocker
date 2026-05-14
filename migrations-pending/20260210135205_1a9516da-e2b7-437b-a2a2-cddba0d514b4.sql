-- Drop the overly permissive policy and replace with a scoped one
DROP POLICY "System automod can update user stats warnings" ON public.forum_user_stats;

-- Only allow updating own stats OR system automod updates
CREATE POLICY "Users and automod can update forum_user_stats"
ON public.forum_user_stats
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);