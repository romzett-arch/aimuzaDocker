#!/bin/bash
# Безопасное применение SQL из migrations-pending без повторных прогонов.

set -euo pipefail

cd "$(dirname "$0")"

if [ "${1:-}" = '--check-bundle' ]; then
  manifest='migrations-pending/pending-manifest.txt'
  test -d migrations-pending && test -f "$manifest" || { echo 'Required migration bundle missing' >&2; exit 1; }
  declare -A listed=()
  while IFS= read -r name || [ -n "$name" ]; do
    name="${name//$'\r'/}"; name="${name#$'\ufeff'}"
    [ -z "$name" ] && continue
    [[ "$name" =~ ^[0-9]{14}_[a-zA-Z0-9_-]+\.sql$ ]] || { echo 'Invalid manifest filename' >&2; exit 1; }
    test -f "migrations-pending/$name" || { echo 'Manifest SQL missing' >&2; exit 1; }
    test -z "${listed[$name]:-}" || { echo 'Duplicate migration manifest entry' >&2; exit 1; }
    listed[$name]=1
  done < "$manifest"
  shopt -s nullglob
  for file in migrations-pending/*.sql; do
    test -n "${listed[$(basename "$file")]:-}" || { echo 'Unlisted pending SQL; refusing deploy' >&2; exit 1; }
  done
  echo 'Migration bundle validated'
  exit 0
fi

if [ ! -d "migrations-pending" ]; then
  echo "Required migrations-pending directory missing" >&2
  exit 1
fi

shopt -s nullglob
if [ "$#" -gt 0 ]; then
  files=()
  for name in "$@"; do
    clean_name="${name//$'\r'/}"
    clean_name="${clean_name#$'\ufeff'}"
    [[ "$clean_name" =~ ^[0-9]{14}_[a-zA-Z0-9_-]+\.sql$ ]] || { echo 'Invalid migration filename' >&2; exit 1; }
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
  [[ "$name" =~ ^[0-9]{14}_[a-zA-Z0-9_-]+\.sql$ ]] || { echo 'Invalid migration filename' >&2; exit 1; }
  if grep -Eiq '^\s*(BEGIN|COMMIT|ROLLBACK)\s*;' "$file"; then
    echo 'Outer transaction statements are forbidden in migrations' >&2; exit 1
  fi
  checksum="$(sha256sum "$file" | awk '{print $1}')"

  applied_checksum="$(docker exec -i aimuza-db psql -U aimuza -d aimuza -At -v ON_ERROR_STOP=1 \
    -c "SELECT COALESCE(NULLIF(checksum, ''), '__missing_checksum__') FROM public.schema_migration_history WHERE file_name = '$name' LIMIT 1;")"

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
  {
    cat "$file"
    printf "\nINSERT INTO public.schema_migration_history (file_name, checksum) VALUES ('%s', '%s') ON CONFLICT (file_name) DO NOTHING;\n" "$name" "$checksum"
  } | docker exec -i aimuza-db psql -U aimuza -d aimuza --single-transaction -v ON_ERROR_STOP=1
done

echo "Pending migrations applied."
