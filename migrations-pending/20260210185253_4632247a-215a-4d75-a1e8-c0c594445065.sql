
CREATE OR REPLACE FUNCTION public.forum_get_user_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats RECORD;
  v_config RECORD;
  v_next_config RECORD;
  v_result jsonb;
BEGIN
  -- Check if stats row exists first (fast path — no write)
  SELECT * INTO v_stats FROM forum_user_stats WHERE user_id = p_user_id;

  -- Only insert if not found
  IF v_stats IS NULL THEN
    INSERT INTO forum_user_stats (user_id) VALUES (p_user_id)
    ON CONFLICT (user_id) DO NOTHING;
    SELECT * INTO v_stats FROM forum_user_stats WHERE user_id = p_user_id;
  END IF;

  SELECT * INTO v_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level;
  SELECT * INTO v_next_config FROM forum_reputation_config WHERE trust_level = v_stats.trust_level + 1;

  v_result := jsonb_build_object(
    'user_id', p_user_id,
    'reputation_score', v_stats.reputation_score,
    'trust_level', v_stats.trust_level,
    'trust_label', COALESCE(v_config.label_ru, 'Новичок'),
    'trust_color', COALESCE(v_config.color, '#888'),
    'trust_icon', v_config.icon,
    'topics_created', v_stats.topics_created,
    'posts_created', v_stats.posts_created,
    'likes_given', v_stats.likes_given,
    'likes_received', v_stats.likes_received,
    'solutions_count', v_stats.solutions_count,
    'warnings_count', v_stats.warnings_count,
    'is_silenced', v_stats.is_silenced,
    'silenced_until', v_stats.silenced_until,
    'can_downvote', COALESCE(v_config.can_downvote, false),
    'can_upload_files', COALESCE(v_config.can_upload_files, false),
    'can_use_reactions', COALESCE(v_config.can_use_reactions, false),
    'next_level_rep', v_next_config.min_reputation,
    'next_level_label', v_next_config.label_ru,
    'progress_to_next', CASE
      WHEN v_next_config.min_reputation IS NULL THEN 100
      WHEN v_config.min_reputation IS NULL THEN 0
      ELSE ROUND(
        ((v_stats.reputation_score - v_config.min_reputation)::numeric /
         GREATEST(v_next_config.min_reputation - v_config.min_reputation, 1)::numeric) * 100
      )
    END
  );

  RETURN v_result;
END;
$$;
