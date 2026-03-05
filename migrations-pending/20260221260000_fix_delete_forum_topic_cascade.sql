DROP FUNCTION IF EXISTS public.delete_forum_topic_cascade(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.delete_forum_topic_cascade(
  p_topic_id UUID,
  p_moderator_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category_id UUID;
  v_post_ids UUID[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = p_moderator_id
      AND role IN ('moderator', 'admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления темы';
  END IF;

  SELECT category_id INTO v_category_id FROM forum_topics WHERE id = p_topic_id;

  IF v_category_id IS NULL THEN
    RAISE EXCEPTION 'Тема не найдена';
  END IF;

  SELECT array_agg(id) INTO v_post_ids FROM forum_posts WHERE topic_id = p_topic_id;

  UPDATE tracks
  SET forum_topic_id = NULL,
      voting_result = NULL,
      voting_started_at = NULL,
      voting_ends_at = NULL,
      voting_likes_count = 0,
      voting_dislikes_count = 0,
      voting_type = NULL,
      moderation_status = CASE
        WHEN moderation_status = 'voting' THEN 'pending'
        ELSE moderation_status
      END
  WHERE forum_topic_id = p_topic_id;

  DELETE FROM forum_reports
    WHERE (target_type = 'topic' AND target_id = p_topic_id)
       OR (target_type = 'post'  AND target_id IN (
            SELECT id FROM forum_posts WHERE topic_id = p_topic_id
          ));

  IF v_post_ids IS NOT NULL THEN
    DELETE FROM forum_post_reactions WHERE post_id = ANY(v_post_ids);
    DELETE FROM forum_post_votes    WHERE post_id = ANY(v_post_ids);
    DELETE FROM forum_attachments   WHERE post_id = ANY(v_post_ids);
  END IF;

  DELETE FROM forum_bookmarks  WHERE topic_id = p_topic_id;
  DELETE FROM forum_drafts     WHERE topic_id = p_topic_id;
  DELETE FROM forum_topic_tags WHERE topic_id = p_topic_id;

  DELETE FROM forum_poll_votes   WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_poll_options WHERE poll_id IN (SELECT id FROM forum_polls WHERE topic_id = p_topic_id);
  DELETE FROM forum_polls        WHERE topic_id = p_topic_id;

  DELETE FROM forum_posts WHERE topic_id = p_topic_id;

  DELETE FROM forum_topics WHERE id = p_topic_id;

  IF v_category_id IS NOT NULL THEN
    UPDATE forum_categories SET
      topics_count = (SELECT COUNT(*) FROM forum_topics WHERE category_id = v_category_id),
      posts_count  = (SELECT COUNT(*) FROM forum_posts fp JOIN forum_topics ft ON fp.topic_id = ft.id WHERE ft.category_id = v_category_id)
    WHERE id = v_category_id;
  END IF;

  INSERT INTO forum_mod_logs (moderator_id, action, target_type, target_id, details)
  VALUES (
    p_moderator_id,
    'delete_topic',
    'topic',
    p_topic_id,
    CASE WHEN p_reason IS NOT NULL
      THEN jsonb_build_object('reason', p_reason)
      ELSE NULL
    END
  );

  RETURN TRUE;
END;
$$;
