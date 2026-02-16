-- Second generation batch - v1
UPDATE public.tracks
SET status = 'completed',
    audio_url = 'https://tempfile.aiquickdraw.com/r/856e9be671de4393898169f204d01698.mp3',
    cover_url = 'https://cdn2.suno.ai/image_4fccfc14-1b68-45ff-812e-483fbbd26af7.jpeg',
    duration = 168
WHERE id = '205e2d58-ac0f-4d46-a007-fdd1bf99cd16';

-- Second generation batch - v2
UPDATE public.tracks
SET status = 'completed',
    audio_url = 'https://tempfile.aiquickdraw.com/r/50e970877b00476ca20be855bbb25ce2.mp3',
    cover_url = 'https://cdn2.suno.ai/image_b0f59768-e8af-44fb-9e73-2fd797441a1d.jpeg',
    duration = 154
WHERE id = 'd59b3344-5585-40df-be0a-7e6e30ff0277';
