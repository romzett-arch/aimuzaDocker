-- Тестовые треки: 2 на пользователя
-- Пользователь 1: romzett@mail.ru (a0000000-0000-0000-0000-000000000001)
-- Пользователь 2: shvedov.roman@mail.ru (d899d095-eb16-4429-923e-dcfdf965e493)

-- User 1, Track 1
UPDATE public.tracks SET
  title = 'In The Spirit of Inward Universe',
  audio_url = 'http://localhost/storage/v1/object/public/tracks/audio/test_track_1.mp3',
  cover_url = 'http://localhost/storage/v1/object/public/tracks/covers/test_cover_1.jpg',
  status = 'completed',
  duration = 155,
  is_public = true,
  genre_id = '8393d790-f2da-4a4b-aa81-93ae7cd38048'
WHERE id = '9b88946e-2a85-4f76-b929-33a8f7ac5449';

-- User 1, Track 2
UPDATE public.tracks SET
  title = 'Test Editor Mix',
  audio_url = 'http://localhost/storage/v1/object/public/tracks/audio/test_track_2.mp3',
  cover_url = 'http://localhost/storage/v1/object/public/tracks/covers/test_cover_2.jpg',
  status = 'completed',
  duration = 180,
  is_public = true,
  genre_id = '67430ce4-0eed-4625-b74c-1e9cc6d8fd20'
WHERE id = '137a4ab4-f053-4a06-aacd-5fc320443b86';

-- User 2, Track 1
INSERT INTO public.tracks (id, user_id, title, audio_url, cover_url, status, duration, is_public, genre_id, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  'd899d095-eb16-4429-923e-dcfdf965e493',
  'Test Editor Remix',
  'http://localhost/storage/v1/object/public/tracks/audio/test_track_3.mp3',
  'http://localhost/storage/v1/object/public/tracks/covers/test_cover_3.jpg',
  'completed', 170, true,
  '8393d790-f2da-4a4b-aa81-93ae7cd38048',
  now(), now()
);

-- User 2, Track 2
INSERT INTO public.tracks (id, user_id, title, audio_url, cover_url, status, duration, is_public, genre_id, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  'd899d095-eb16-4429-923e-dcfdf965e493',
  'In This City',
  'http://localhost/storage/v1/object/public/tracks/audio/test_track_4.mp3',
  'http://localhost/storage/v1/object/public/tracks/covers/test_cover_4.jpg',
  'completed', 134, true,
  '67430ce4-0eed-4625-b74c-1e9cc6d8fd20',
  now(), now()
);

-- Проверка
SELECT id, user_id, title, status, audio_url IS NOT NULL as has_audio, cover_url IS NOT NULL as has_cover, duration, genre_id
FROM public.tracks
WHERE user_id IN ('a0000000-0000-0000-0000-000000000001', 'd899d095-eb16-4429-923e-dcfdf965e493')
ORDER BY user_id, created_at DESC
LIMIT 6;
