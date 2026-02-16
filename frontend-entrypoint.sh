#!/bin/sh
# ══════════════════════════════════════════════════
# Frontend Runtime Config Injection
# Генерирует /runtime-config.js из переменных окружения
# чтобы один образ работал и на localhost, и на aimuza.ru
# ══════════════════════════════════════════════════

CONFIG_FILE="/usr/share/nginx/html/runtime-config.js"

echo "window.__RUNTIME_CONFIG__ = {" > "$CONFIG_FILE"
echo "  ANON_KEY: \"${ANON_KEY:-}\"," >> "$CONFIG_FILE"
echo "  APP_NAME: \"${APP_NAME:-AI Planet Sound}\"," >> "$CONFIG_FILE"
echo "  SENTRY_DSN: \"${SENTRY_DSN:-}\"" >> "$CONFIG_FILE"
echo "};" >> "$CONFIG_FILE"

echo "[runtime-config] Generated $CONFIG_FILE"
if [ -n "$ANON_KEY" ]; then
  echo "[runtime-config] ANON_KEY: set (${#ANON_KEY} chars)"
else
  echo "[runtime-config] ANON_KEY: NOT SET (will use fallback from build)"
fi
if [ -n "$SENTRY_DSN" ]; then
  echo "[runtime-config] SENTRY_DSN: set"
else
  echo "[runtime-config] SENTRY_DSN: NOT SET (Sentry disabled)"
fi

# Запуск nginx (стандартный entrypoint)
exec nginx -g "daemon off;"
