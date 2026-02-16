-- Update all generated tracks to use local storage URLs
UPDATE public.tracks
SET audio_url = 'http://localhost/storage/v1/object/public/tracks/audio/' || id || '.mp3',
    cover_url = 'http://localhost/storage/v1/object/public/tracks/covers/' || id || '.jpg'
WHERE id IN (
  '7ff67760-b0dd-4bf4-904a-1519904337c6',
  '219028eb-1c39-4b20-adf6-66713e2ae742',
  '205e2d58-ac0f-4d46-a007-fdd1bf99cd16',
  'd59b3344-5585-40df-be0a-7e6e30ff0277'
);

-- Assign genre: use Electronic/Electropop if exists
UPDATE public.tracks t
SET genre_id = (
  SELECT id FROM public.genres
  WHERE name_ru = 'Электропоп' OR name ILIKE '%electro%' OR name ILIKE '%pop%'
  ORDER BY sort_order LIMIT 1
)
WHERE t.id IN (
  '7ff67760-b0dd-4bf4-904a-1519904337c6',
  '219028eb-1c39-4b20-adf6-66713e2ae742',
  '205e2d58-ac0f-4d46-a007-fdd1bf99cd16',
  'd59b3344-5585-40df-be0a-7e6e30ff0277'
)
AND t.genre_id IS NULL;
