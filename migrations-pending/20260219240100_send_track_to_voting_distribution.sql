-- Update send_track_to_voting: set distribution_status = 'voting' when track is in distribution flow
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
BEGIN
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
  
  -- When distribution_status = 'pending_moderation', also set distribution_status = 'voting'
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
