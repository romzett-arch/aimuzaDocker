-- Полное удаление addon_services для удалённых функций (код полностью удалён из проекта)
DELETE FROM addon_services
WHERE name IN (
  'boost_track_1h', 'boost_track_6h', 'boost_track_24h', 'boost_track_48h',
  'boost_style',
  'timestamped_lyrics',
  'analyze_lyrics',
  'vocal_separation',
  'stem_separation',
  'add_vocal',
  'ringtone',
  'large_cover',
  'short_video',
  'forum_improve_text'
);

-- Удаление таблицы feature_trials и связанных функций
DROP FUNCTION IF EXISTS use_feature_trial(uuid, text);
DROP FUNCTION IF EXISTS get_trial_remaining(uuid, text);
DROP TABLE IF EXISTS feature_trials;

-- Удаление trial-настроек
DELETE FROM settings WHERE key LIKE 'trial_%';

-- Удаление premium feature toggles
DELETE FROM settings WHERE key IN (
  'feature_hd_covers',
  'feature_beat_store',
  'feature_unlimited_downloads',
  'feature_priority_generation',
  'feature_generation_discount',
  'feature_prompt_store',
  'feature_premium_prompts_marketplace',
  'feature_premium_lyrics_editor'
);

-- Удаление функций boost track
DROP FUNCTION IF EXISTS purchase_track_boost(uuid, text);
DROP FUNCTION IF EXISTS get_boosted_tracks();

-- Деактивация промоакций
UPDATE track_promotions SET is_active = false WHERE is_active = true;

-- Удаление функции покупки бита
DROP FUNCTION IF EXISTS process_beat_purchase(uuid, uuid);
