-- Fix storage URLs: replace internal Docker address with public URL
-- Problem: Deno functions used getPublicUrl() with SUPABASE_URL=http://api:3000,
-- resulting in unreachable URLs stored in the database.

UPDATE tracks SET
  audio_url = REPLACE(audio_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE audio_url LIKE 'http://api:3000/%';

UPDATE tracks SET
  cover_url = REPLACE(cover_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE cover_url LIKE 'http://api:3000/%';

UPDATE tracks SET
  wav_url = REPLACE(wav_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE wav_url LIKE 'http://api:3000/%';

UPDATE tracks SET
  master_audio_url = REPLACE(master_audio_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE master_audio_url LIKE 'http://api:3000/%';

UPDATE tracks SET
  certificate_url = REPLACE(certificate_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE certificate_url LIKE 'http://api:3000/%';

UPDATE tracks SET
  gold_pack_url = REPLACE(gold_pack_url, 'http://api:3000/', 'https://aimuza.ru/')
WHERE gold_pack_url LIKE 'http://api:3000/%';

UPDATE track_addons SET
  result_url = REPLACE(result_url::text, 'http://api:3000/', 'https://aimuza.ru/')
WHERE result_url::text LIKE '%http://api:3000/%' AND result_url::text NOT LIKE '{%';

UPDATE notifications SET
  metadata = jsonb_set(metadata, '{wav_url}',
    to_jsonb(REPLACE(metadata->>'wav_url', 'http://api:3000/', 'https://aimuza.ru/')))
WHERE metadata->>'wav_url' LIKE 'http://api:3000/%';
