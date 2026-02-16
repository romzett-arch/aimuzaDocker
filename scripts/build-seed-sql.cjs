#!/usr/bin/env node
/**
 * Генерируем seed SQL из full-backup JSON.
 * Вставляет данные во все таблицы из бэкапа.
 */
const fs = require('fs');
const path = require('path');

const BACKUP = path.join(__dirname, '..', '..', 'full-backup-2026-02-13.json');
const OUTPUT = path.join(__dirname, '..', 'init-db', '002-seed.sql');

const data = JSON.parse(fs.readFileSync(BACKUP, 'utf8'));

function escapeSQL(val) {
  if (val === null || val === undefined) return 'NULL';
  if (typeof val === 'boolean') return val ? 'TRUE' : 'FALSE';
  if (typeof val === 'number') return String(val);
  if (typeof val === 'object') return `'${JSON.stringify(val).replace(/'/g, "''")}'::jsonb`;
  return `'${String(val).replace(/'/g, "''")}'`;
}

// Порядок вставки (учитываем FK зависимости)
const INSERT_ORDER = [
  'genre_categories',
  'genres',
  'ai_models',
  'templates',
  'artist_styles',
  'vocal_types',
  'addon_services',
  'settings',
  'subscription_plans',
  'achievements',
  'profiles',       // нужен auth.users сначала!
  'tracks',
  'user_prompts',
  'generated_lyrics',
  'lyrics_items',
  'playlists',
  'playlist_tracks',
  'track_likes',
  'track_comments',
  'user_follows',
  'payments',
  'user_roles',
  'notifications',
  'contests',
  'contest_entries',
  'referral_codes',
  'referrals',
  'store_items',
  'item_purchases',
  'subscriptions',
  'user_achievements',
];

let sql = `-- =====================================================
-- SEED DATA from backup ${data.exported_at}
-- =====================================================

-- Сначала вставляем auth.users из profiles (нужны для FK)
`;

// Извлекаем user_id из profiles для auth.users
const profiles = data.tables.profiles?.data || [];
if (profiles.length > 0) {
  sql += `INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at) VALUES\n`;
  const userRows = profiles.map((p, i) => {
    const email = `user${i + 1}@aimuza.ru`; // placeholder email
    return `  (${escapeSQL(p.user_id)}, ${escapeSQL(email)}, '$2a$10$placeholder', now(), ${escapeSQL(p.created_at)})`;
  });
  sql += userRows.join(',\n') + `\nON CONFLICT (id) DO NOTHING;\n\n`;
}

// Вставляем данные по порядку
for (const tableName of INSERT_ORDER) {
  const table = data.tables[tableName];
  if (!table || !table.data || table.data.length === 0) {
    sql += `-- ${tableName}: пусто (${table?.count || 0} rows)\n\n`;
    continue;
  }

  const rows = table.data;
  const columns = Object.keys(rows[0]);
  
  sql += `-- ${tableName}: ${rows.length} rows\n`;
  sql += `INSERT INTO public.${tableName} (${columns.map(c => `"${c}"`).join(', ')}) VALUES\n`;

  const valueRows = rows.map(row => {
    const vals = columns.map(col => escapeSQL(row[col]));
    return `  (${vals.join(', ')})`;
  });

  sql += valueRows.join(',\n') + `\nON CONFLICT DO NOTHING;\n\n`;
}

// Обновляем sequences
sql += `
-- Обновляем sequences
SELECT setval(pg_get_serial_sequence(schemaname || '.' || tablename, 'id'), COALESCE(max(id::text::bigint), 1))
FROM pg_tables
CROSS JOIN LATERAL (SELECT max(id) FROM information_schema.columns WHERE table_name = pg_tables.tablename AND column_name = 'id') sub
WHERE schemaname = 'public';
`;

fs.writeFileSync(OUTPUT, sql, 'utf8');
console.log(`Seed written to ${OUTPUT} (${(sql.length / 1024).toFixed(0)} KB, ${profiles.length} users)`);
