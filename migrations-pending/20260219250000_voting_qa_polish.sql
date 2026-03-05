-- QA Polish: Forum Lock, Anti-duplicate, Visibility
-- 1. resolve_track_voting: lock forum topic + post closure message on completion
-- 2. send_track_to_voting: reject if track already in active voting

-- 1. Update resolve_track_voting: lock forum topic when voting completes
CREATE OR REPLACE FUNCTION public.resolve_track_voting(
  p_track_id UUID,
  p_manual_result TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_track RECORD;
  v_total_votes INTEGER;
  v_total_weight NUMERIC;
  v_min_votes INTEGER;
  v_approval_ratio NUMERIC;
  v_like_ratio NUMERIC;
  v_result TEXT;
  v_new_status TEXT;
  v_new_distribution_status TEXT;
  v_is_distribution_voting BOOLEAN;
  v_closure_msg TEXT;
BEGIN
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Track not found');
  END IF;
  
  v_is_distribution_voting := (v_track.distribution_status = 'voting');
  
  -- Manual override from moderator
  IF p_manual_result IS NOT NULL THEN
    v_result := p_manual_result;
    v_new_status := CASE 
      WHEN p_manual_result = 'approved' THEN 'pending'
      ELSE 'rejected'
    END;
    v_new_distribution_status := CASE 
      WHEN v_is_distribution_voting AND p_manual_result = 'approved' THEN 'pending_master'
      WHEN v_is_distribution_voting AND p_manual_result = 'rejected' THEN 'rejected'
      ELSE v_track.distribution_status
    END;
    
    UPDATE public.tracks SET
      moderation_status = v_new_status,
      distribution_status = v_new_distribution_status,
      voting_result = 'manual_override_' || p_manual_result,
      is_public = false
    WHERE id = p_track_id;
    
    -- Forum Lock: post closure message and lock topic
    IF v_track.forum_topic_id IS NOT NULL THEN
      v_closure_msg := '✅ **Голосование завершено. Решение принято.**' || E'\n\n' ||
        CASE WHEN p_manual_result = 'approved'
          THEN 'Трек одобрен для дистрибуции.'
          ELSE 'Трек не прошёл голосование.'
        END;
      INSERT INTO public.forum_posts (topic_id, user_id, content)
      VALUES (v_track.forum_topic_id, '00000000-0000-0000-0000-000000000000', v_closure_msg);
      UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
    END IF;
    
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track.user_id,
      'voting_result',
      CASE WHEN p_manual_result = 'approved' 
        THEN '🎉 Голосование пройдено!' 
        ELSE 'Голосование завершено'
      END,
      CASE WHEN p_manual_result = 'approved'
        THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
        ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
      END,
      'track',
      p_track_id
    );
    
    RETURN jsonb_build_object(
      'success', true,
      'result', p_manual_result,
      'method', 'manual_override',
      'new_moderation_status', v_new_status,
      'new_distribution_status', v_new_distribution_status
    );
  END IF;
  
  -- Automatic: use weighted votes for ratio, voter count for min check
  v_total_weight := COALESCE(v_track.weighted_likes_sum, 0) + COALESCE(v_track.weighted_dislikes_sum, 0);
  v_total_votes := COALESCE(v_track.voting_likes_count, 0) + COALESCE(v_track.voting_dislikes_count, 0);
  
  SELECT COALESCE(value::integer, 10) INTO v_min_votes
  FROM public.settings WHERE key = 'voting_min_votes';
  
  SELECT COALESCE(value::numeric, 0.6) INTO v_approval_ratio
  FROM public.settings WHERE key = 'voting_approval_ratio';
  
  IF v_total_weight > 0 THEN
    v_like_ratio := COALESCE(v_track.weighted_likes_sum, 0) / v_total_weight;
  ELSIF v_total_votes > 0 THEN
    v_like_ratio := COALESCE(v_track.voting_likes_count, 0)::numeric / v_total_votes;
  ELSE
    v_like_ratio := 0;
  END IF;
  
  IF v_total_votes < v_min_votes AND v_total_weight < v_min_votes THEN
    v_result := 'rejected';
    v_new_status := 'rejected';
  ELSIF v_total_weight > 0 AND v_total_weight >= v_min_votes THEN
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved';
      v_new_status := 'pending';
    ELSE
      v_result := 'rejected';
      v_new_status := 'rejected';
    END IF;
  ELSIF v_total_votes >= v_min_votes THEN
    IF v_like_ratio >= v_approval_ratio THEN
      v_result := 'voting_approved';
      v_new_status := 'pending';
    ELSE
      v_result := 'rejected';
      v_new_status := 'rejected';
    END IF;
  ELSE
    v_result := 'rejected';
    v_new_status := 'rejected';
  END IF;
  
  v_new_distribution_status := CASE 
    WHEN v_is_distribution_voting AND v_result = 'voting_approved' THEN 'pending_master'
    WHEN v_is_distribution_voting AND v_result = 'rejected' THEN 'rejected'
    ELSE v_track.distribution_status
  END;
  
  UPDATE public.tracks SET
    moderation_status = v_new_status,
    distribution_status = v_new_distribution_status,
    voting_result = v_result,
    is_public = false
  WHERE id = p_track_id;
  
  -- Forum Lock: post closure message and lock topic
  IF v_track.forum_topic_id IS NOT NULL THEN
    v_closure_msg := '✅ **Голосование завершено. Решение принято.**' || E'\n\n' ||
      CASE WHEN v_result = 'voting_approved'
        THEN 'Трек одобрен для дистрибуции (' || ROUND(v_like_ratio * 100) || '% положительных голосов).'
        ELSE 'Трек не прошёл голосование (' || ROUND(v_like_ratio * 100) || '% положительных, требуется ' || ROUND(v_approval_ratio * 100) || '%).'
      END;
    INSERT INTO public.forum_posts (topic_id, user_id, content)
    VALUES (v_track.forum_topic_id, '00000000-0000-0000-0000-000000000000', v_closure_msg);
    UPDATE public.forum_topics SET is_locked = true, is_pinned = false WHERE id = v_track.forum_topic_id;
  END IF;
  
  INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
  VALUES (
    v_track.user_id,
    'voting_result',
    CASE WHEN v_result = 'voting_approved' 
      THEN '🎉 Голосование пройдено!' 
      ELSE 'Голосование завершено'
    END,
    CASE WHEN v_result = 'voting_approved'
      THEN 'Трек "' || v_track.title || '" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.'
      ELSE 'К сожалению, трек "' || v_track.title || '" не набрал достаточно голосов.'
    END,
    'track',
    p_track_id
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'result', v_result,
    'total_votes', v_total_votes,
    'like_ratio', v_like_ratio,
    'min_votes_required', v_min_votes,
    'approval_ratio_required', v_approval_ratio,
    'new_moderation_status', v_new_status,
    'new_distribution_status', v_new_distribution_status
  );
END;
$$;

-- 2. Update send_track_to_voting: reject if already in active voting
CREATE OR REPLACE FUNCTION public.send_track_to_voting(
  p_track_id UUID,
  p_duration_days INTEGER DEFAULT NULL,
  p_voting_type TEXT DEFAULT 'public'
)
RETURNS JSONB AS $$
DECLARE
  v_duration INTEGER;
  v_ends_at TIMESTAMP WITH TIME ZONE;
  v_track_owner UUID;
  v_current_status TEXT;
  v_current_ends_at TIMESTAMP WITH TIME ZONE;
BEGIN
  -- Anti-duplicate: reject if track already in active voting
  SELECT moderation_status, voting_ends_at INTO v_current_status, v_current_ends_at
  FROM public.tracks WHERE id = p_track_id;
  
  IF v_current_status = 'voting' AND v_current_ends_at IS NOT NULL AND v_current_ends_at > now() THEN
    RAISE EXCEPTION 'Трек уже находится в активном голосовании. Дождитесь завершения или завершите его досрочно.';
  END IF;
  
  SELECT user_id INTO v_track_owner FROM public.tracks WHERE id = p_track_id;
  
  IF p_duration_days IS NULL THEN
    SELECT COALESCE(value::integer, 7) INTO v_duration
    FROM public.settings WHERE key = 'voting_duration_days';
  ELSE
    v_duration := p_duration_days;
  END IF;
  
  IF p_voting_type = 'internal' AND p_duration_days IS NULL THEN
    v_duration := 1;
  END IF;
  
  v_ends_at := now() + (v_duration || ' days')::interval;
  
  UPDATE public.tracks SET
    moderation_status = 'voting',
    distribution_status = CASE WHEN distribution_status = 'pending_moderation' THEN 'voting' ELSE distribution_status END,
    voting_type = p_voting_type,
    voting_started_at = now(),
    voting_ends_at = v_ends_at,
    voting_result = 'pending',
    voting_likes_count = 0,
    voting_dislikes_count = 0,
    is_public = CASE WHEN p_voting_type = 'public' THEN true ELSE false END
  WHERE id = p_track_id;
  
  IF v_track_owner IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
    VALUES (
      v_track_owner,
      'voting_started',
      CASE WHEN p_voting_type = 'public' 
        THEN '🗳️ Трек на голосовании сообщества'
        ELSE '🗳️ Трек на внутреннем голосовании'
      END,
      'Ваш трек отправлен на голосование. Результаты будут известны через ' || v_duration || ' дней.',
      'track',
      p_track_id
    );
  END IF;
  
  RETURN jsonb_build_object(
    'success', true,
    'voting_type', p_voting_type,
    'voting_ends_at', v_ends_at,
    'duration_days', v_duration
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
