-- Safe showcase: never expose lyrics, prompts, drafts or private tracks from an idea.

CREATE OR REPLACE VIEW public.song_idea_public_results
WITH (security_invoker = true)
AS
SELECT d.idea_id,
       t.id AS track_id,
       t.title,
       t.created_at,
       COALESCE(g.name, '') AS genre
FROM public.song_idea_generation_attempts a
JOIN public.song_idea_discoveries d ON d.id = a.discovery_id
JOIN public.tracks t ON t.id = a.track_id
LEFT JOIN public.genres g ON g.id = t.genre_id
WHERE t.is_public = true
  AND t.status = 'completed';

GRANT SELECT ON public.song_idea_public_results TO authenticated;
