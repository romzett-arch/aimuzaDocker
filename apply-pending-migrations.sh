#!/bin/bash
# Безопасное применение SQL из migrations-pending без повторных прогонов.

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -d "migrations-pending" ]; then
  echo "migrations-pending not found, skip"
  exit 0
fi

shopt -s nullglob
if [ "$#" -gt 0 ]; then
  files=()
  for name in "$@"; do
    clean_name="${name//$'\r'/}"
    clean_name="${clean_name#$'\ufeff'}"
    files+=("migrations-pending/$clean_name")
  done
else
  files=(migrations-pending/*.sql)
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "No SQL files in migrations-pending."
  exit 0
fi

echo "Ensuring migration history table..."
docker exec -i aimuza-db psql -U aimuza -d aimuza -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migration_history (
  file_name TEXT PRIMARY KEY,
  checksum TEXT,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

for file in "${files[@]}"; do
  if [ ! -f "$file" ]; then
    if [ "$#" -gt 0 ]; then
      echo "Missing requested migration: $file" >&2
      exit 1
    fi

    echo "Skip missing file: $file"
    continue
  fi

  name="$(basename "$file")"
  checksum="$(sha256sum "$file" | awk '{print $1}')"

  applied_checksum="$(docker exec -i aimuza-db psql -U aimuza -d aimuza -At -v ON_ERROR_STOP=1 \
    -c "SELECT COALESCE(checksum, '') FROM public.schema_migration_history WHERE file_name = '$name' LIMIT 1;")"

  if [ -n "$applied_checksum" ]; then
    if [ "$applied_checksum" != "$checksum" ]; then
      echo "Checksum mismatch for already applied migration: $name" >&2
      echo "Expected: $applied_checksum" >&2
      echo "Actual:   $checksum" >&2
      exit 1
    fi
    echo "Skip already applied: $name"
    continue
  fi

  echo "Apply: $name"
  docker exec -i aimuza-db psql -U aimuza -d aimuza -v ON_ERROR_STOP=1 < "$file"
  docker exec -i aimuza-db psql -U aimuza -d aimuza -v ON_ERROR_STOP=1 \
    -c "INSERT INTO public.schema_migration_history (file_name, checksum) VALUES ('$name', '$checksum') ON CONFLICT (file_name) DO NOTHING;"
done

echo "Pending migrations applied."
