UPDATE public.tracks
SET cover_url = NULL,
    updated_at = now()
WHERE cover_url LIKE 'https://musicfile.removeai.ai/%';
