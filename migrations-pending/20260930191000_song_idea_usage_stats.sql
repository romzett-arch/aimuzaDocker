-- Records successful creation requests from a selected idea and exposes aggregate stats.

CREATE OR REPLACE FUNCTION public.mark_song_idea_used(p_idea_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.song_idea_discoveries
  SET used_at = COALESCE(used_at, now())
  WHERE user_id = auth.uid() AND idea_id = p_idea_id AND accepted_at IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Идея не принята текущим пользователем';
  END IF;
END;
$$;

CREATE OR REPLACE VIEW public.song_idea_public_stats WITH (security_invoker = true) AS
SELECT i.id AS idea_id,
       count(d.accepted_at) FILTER (WHERE d.accepted_at IS NOT NULL)::integer AS accepted_count,
       count(d.used_at) FILTER (WHERE d.used_at IS NOT NULL)::integer AS successful_generation_count
FROM public.song_ideas i
LEFT JOIN public.song_idea_discoveries d ON d.idea_id = i.id
WHERE i.is_published
GROUP BY i.id;

GRANT EXECUTE ON FUNCTION public.mark_song_idea_used(UUID) TO authenticated;
GRANT SELECT ON public.song_idea_public_stats TO authenticated;
