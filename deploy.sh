#!/bin/bash
# ═══════════════════════════════════════════════
# AIMUZA — Production Deploy
# Запуск на сервере: cd /opt/aimuza/deploy && bash deploy.sh
# Маршрут: Docker Hub → Сервер
# ═══════════════════════════════════════════════

set -eo pipefail

COMPOSE_FILE="docker-compose.prod.yml"
PENDING_DIR="migrations-pending"
PENDING_MANIFEST="$PENDING_DIR/pending-manifest.txt"
PULL_ATTEMPTS="${PULL_ATTEMPTS:-4}"
PULL_DELAY_SECONDS="${PULL_DELAY_SECONDS:-5}"

require_env_key() {
    local key="$1"
    local value

    value="$(grep -E "^${key}=" ".env" | tail -n 1 | cut -d= -f2- || true)"
    value="${value%$'\r'}"

    if [ -z "$value" ]; then
        echo "❌ ${key} отсутствует или пустой в .env"
        exit 1
    fi

    case "$value" in
        CHANGE_ME*|change_me*|REPLACE_ME*|replace_me*)
            echo "❌ ${key} содержит placeholder в .env"
            exit 1
            ;;
    esac
}

require_container_env() {
    local container="$1"
    local key="$2"
    local value

    value="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "^${key}=" | tail -n 1 | cut -d= -f2- || true)"
    value="${value%$'\r'}"

    if [ -z "$value" ]; then
        echo "❌ ${container}: ${key} пустой внутри контейнера"
        exit 1
    fi
}

resolve_host() {
    local host="$1"

    if command -v getent >/dev/null 2>&1 && getent ahosts "$host" >/dev/null 2>&1; then
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1 && nslookup "$host" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

print_pull_failure_hint() {
    local log_file="$1"

    if grep -qiE 'lookup .*docker\.io|Temporary failure in name resolution|server misbehaving|no such host|i/o timeout' "$log_file"; then
        echo "⚠ Похоже на проблему DNS при обращении к Docker Hub."
        echo "  Сервер не смог зарезолвить registry-1.docker.io/auth.docker.io."
        echo "  После обновления deploy-скрипта pull будет повторён автоматически."
    fi
}

pull_images_with_retry() {
    local log_file
    local attempt
    local delay
    local status
    local host

    log_file="$(mktemp /tmp/aimuza-docker-pull.XXXXXX.log)"
    delay="$PULL_DELAY_SECONDS"
    status=1

    for host in registry-1.docker.io auth.docker.io; do
        if resolve_host "$host"; then
            echo "   DNS OK: $host"
        else
            echo "   DNS WARN: $host пока не резолвится"
        fi
    done

    for ((attempt=1; attempt<=PULL_ATTEMPTS; attempt++)); do
        echo "   Pull attempt ${attempt}/${PULL_ATTEMPTS}..."

        if docker compose -f "$COMPOSE_FILE" pull 2>&1 | tee "$log_file"; then
            rm -f "$log_file"
            return 0
        fi

        status=${PIPESTATUS[0]}
        print_pull_failure_hint "$log_file"

        if [ "$attempt" -lt "$PULL_ATTEMPTS" ]; then
            echo "   Pull failed, retry in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    echo "❌ Не удалось скачать образы после ${PULL_ATTEMPTS} попыток."
    print_pull_failure_hint "$log_file"
    rm -f "$log_file"
    return "$status"
}

echo "╔══════════════════════════════════════════╗"
echo "║   AIMUZA — Production Deploy    ║"
echo "╚══════════════════════════════════════════╝"

cd "$(dirname "$0")"

# Проверяем .env
if [ ! -f ".env" ]; then
    echo "❌ Файл .env не найден!"
    echo "   cp .env.production .env && nano .env"
    exit 1
fi

for key in ROBOKASSA_MERCHANT_LOGIN ROBOKASSA_PASSWORD1 ROBOKASSA_PASSWORD2; do
    require_env_key "$key"
done

echo "📥 Шаг 1: Pull свежих образов с Docker Hub..."
pull_images_with_retry

echo ""
echo "🚀 Шаг 2: Перезапуск контейнеров..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans

echo ""
echo "⏳ Шаг 3: Ожидание healthcheck (15 сек)..."
sleep 15

echo ""
echo "📊 Шаг 4: Статус контейнеров:"
docker compose -f "$COMPOSE_FILE" ps

if [ "$(docker inspect aimuza-deno --format '{{.State.Status}}')" != "running" ]; then
    echo "❌ aimuza-deno не запущен после деплоя"
    exit 1
fi

for key in ROBOKASSA_MERCHANT_LOGIN ROBOKASSA_PASSWORD1 ROBOKASSA_PASSWORD2; do
    require_container_env "aimuza-deno" "$key"
done

echo "✅ aimuza-deno пересоздан с актуальным env"

echo ""
echo "🗄️ Шаг 5: Применение pending-миграций..."
if [ -f "apply-pending-migrations.sh" ]; then
    pending_files=()

    if [ -f "$PENDING_MANIFEST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            clean_line="${line//$'\r'/}"
            clean_line="${clean_line#$'\ufeff'}"

            if [ -n "$clean_line" ]; then
                pending_files+=("$clean_line")
            fi
        done < "$PENDING_MANIFEST"
    fi

    if [ ${#pending_files[@]} -gt 0 ]; then
        bash ./apply-pending-migrations.sh "${pending_files[@]}"
        rm -f "$PENDING_MANIFEST"

        for migration in "${pending_files[@]}"; do
            rm -f "$PENDING_DIR/$migration"
        done

        echo "✅ Pending-миграции применены: ${#pending_files[@]}"
    else
        rm -f "$PENDING_MANIFEST"
        rm -f "$PENDING_DIR"/*.sql 2>/dev/null || true
        echo "   pending-manifest пуст, новых миграций нет"
    fi
else
    echo "   ⚠ apply-pending-migrations.sh не найден, пропуск"
fi

echo ""
echo "📄 Шаг 6: Синхронизация nginx config..."
if [ -f "nginx/aimuza.ru.prod.conf" ]; then
    cp nginx/aimuza.ru.prod.conf /etc/nginx/sites-available/aimuza.ru
    ln -sf /etc/nginx/sites-available/aimuza.ru /etc/nginx/sites-enabled/aimuza.ru
    echo "   nginx/aimuza.ru.prod.conf → sites-available + sites-enabled (symlink)"
else
    echo "   ⚠ nginx/aimuza.ru.prod.conf не найден, пропуск"
fi

echo ""
echo "🔄 Шаг 7: Перезагрузка Nginx..."
nginx -t && nginx -s reload
echo "✅ Nginx перезагружен"

echo ""
echo "🧹 Шаг 8: Очистка старых образов..."
docker image prune -f

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         ✅ Деплой завершён!              ║"
echo "║   Сайт: https://aimuza.ru               ║"
echo "║   Health: https://aimuza.ru/health       ║"
echo "╚══════════════════════════════════════════╝"
