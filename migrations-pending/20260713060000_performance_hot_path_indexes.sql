-- Indexes for the highest-traffic feed, forum and notification queries.
-- Keep predicates aligned with the public list queries so PostgreSQL can
-- satisfy filtering and ordering from the same index.

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_created_at
  ON public.forum_posts (topic_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_forum_topics_visible_bumped
  ON public.forum_topics (is_pinned DESC, bumped_at DESC)
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_forum_topics_category_visible_bumped
  ON public.forum_topics (category_id, is_pinned DESC, bumped_at DESC)
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_forum_topics_visible_votes
  ON public.forum_topics (votes_score DESC)
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_forum_topics_visible_created
  ON public.forum_topics (created_at DESC)
  WHERE is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_notifications_user_created
  ON public.notifications (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_track_likes_track_created
  ON public.track_likes (track_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_follows_following_created
  ON public.user_follows (following_id, created_at DESC);

