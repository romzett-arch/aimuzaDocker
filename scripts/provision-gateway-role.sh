#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
value=$(sed -n 's/^GATEWAY_DB_PASSWORD=//p' .env | tr -d '\r' | tail -n 1)
case "$value" in ''|*[!0-9a-f]*) echo 'GATEWAY_DB_PASSWORD must be a generated hex secret' >&2; exit 1;; esac
[ "${#value}" -eq 64 ] || { echo 'Gateway secret must be 64 hex characters' >&2; exit 1; }
printf "ALTER ROLE aimuza_gateway LOGIN PASSWORD '%s';\n" "$value" |
 docker exec -i aimuza-db psql -X -U aimuza -d aimuza -v ON_ERROR_STOP=1 >/dev/null
