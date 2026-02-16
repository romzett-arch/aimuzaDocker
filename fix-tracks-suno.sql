-- v1 track
UPDATE public.tracks
SET status = 'completed',
    audio_url = 'https://tempfile.aiquickdraw.com/r/b62e53cda32347619ce8479a4f1f8940.mp3',
    cover_url = 'https://cdn2.suno.ai/image_c12d6de9-8557-44fe-888a-93e6f6e91f34.jpeg',
    duration = 170
WHERE id = '7ff67760-b0dd-4bf4-904a-1519904337c6';

-- v2 track
UPDATE public.tracks
SET status = 'completed',
    audio_url = 'https://tempfile.aiquickdraw.com/r/9841cd3bc396457cbdb185e2277c42da.mp3',
    cover_url = 'https://cdn2.suno.ai/image_82e4ce82-2663-4aa2-9f06-cb3fb345b347.jpeg',
    duration = 154
WHERE id = '219028eb-1c39-4b20-adf6-66713e2ae742';
