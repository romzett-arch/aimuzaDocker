#!/usr/bin/env node
/**
 * Собираем единый init.sql из:
 * 1. Своя auth-схема (замена Supabase Auth)
 * 2. Все 183 миграции Supabase в порядке создания
 * 3. Патчи для совместимости (убираем RLS Supabase-специфику)
 */
const fs = require('fs');
const path = require('path');

const MIGRATIONS_DIR = path.join(__dirname, '..', '..', 'supabase', 'migrations');
const OUTPUT = path.join(__dirname, '..', 'init-db', '001-schema.sql');

// 1. Auth schema — замена Supabase auth.users
const AUTH_SCHEMA = `
-- =====================================================
-- AUTH SCHEMA: замена Supabase auth.users
-- =====================================================
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT UNIQUE,
  encrypted_password TEXT,
  email_confirmed_at TIMESTAMPTZ,
  raw_user_meta_data JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  last_sign_in_at TIMESTAMPTZ,
  is_super_admin BOOLEAN DEFAULT false
);

-- Индексы
CREATE INDEX IF NOT EXISTS idx_auth_users_email ON auth.users(email);

-- Функция для совместимости (auth.uid() используется в RLS)
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID;
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION auth.role() RETURNS TEXT AS $$
  SELECT COALESCE(current_setting('request.jwt.claim.role', true), 'anon');
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION auth.email() RETURNS TEXT AS $$
  SELECT current_setting('request.jwt.claim.email', true);
$$ LANGUAGE SQL STABLE;

`;

// 2. Собираем все миграции
const files = fs.readdirSync(MIGRATIONS_DIR)
  .filter(f => f.endsWith('.sql'))
  .sort(); // сортировка по имени = по дате

console.log(`Found ${files.length} migration files`);

let migrations = '';
for (const file of files) {
  const content = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
  migrations += `\n-- =====================================================\n`;
  migrations += `-- Migration: ${file}\n`;
  migrations += `-- =====================================================\n`;
  migrations += content + '\n';
}

// 3. Патчи: убираем Supabase-специфичные конструкции, которые не работают без Supabase
let patched = migrations;

// Убираем ALTER TABLE ... ENABLE ROW LEVEL SECURITY (оставляем таблицы без RLS для API-контроля)
// НЕ удаляем — PostgreSQL поддерживает RLS нативно, но мы его не включаем на данном этапе
// patched = patched.replace(/ALTER TABLE .+ ENABLE ROW LEVEL SECURITY;/g, '-- [PATCHED] RLS disabled for API mode');

// Заменяем references auth.users на каскадное удаление (уже есть в оригинале)

// 4. Собираем итоговый файл
const output = `-- =====================================================
-- AI Planet Sound (aimuza.ru) — init database
-- Auto-generated from ${files.length} Supabase migrations
-- Generated at: ${new Date().toISOString()}
-- =====================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

${AUTH_SCHEMA}

-- =====================================================
-- PUBLIC SCHEMA: all migrations
-- =====================================================
${patched}
`;

fs.writeFileSync(OUTPUT, output, 'utf8');
console.log(`Written to ${OUTPUT} (${(output.length / 1024).toFixed(0)} KB)`);
