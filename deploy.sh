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

assert_public_url() {
    local url="$1"
    local label="$2"

    if ! curl -fsS "$url" >/dev/null; then
        echo "❌ ${label} недоступен: $url"
        exit 1
    fi

    echo "   OK: ${label}"
}

assert_content_type() {
    local url="$1"
    local expected="$2"
    local label="$3"
    local headers

    headers="$(curl -fsSI "$url" | tr -d '\r')"
    if ! printf '%s\n' "$headers" | grep -iq "^Content-Type: ${expected}"; then
        echo "❌ ${label}: ожидался Content-Type ${expected}, получено:"
        printf '%s\n' "$headers"
        exit 1
    fi

    echo "   OK: ${label} (${expected})"
}

assert_html_contains() {
    local url="$1"
    local needle="$2"
    local label="$3"

    if ! curl -fsS "$url" | grep -F "$needle" >/dev/null; then
        echo "❌ ${label}: HTML не содержит ожидаемую ссылку ${needle}"
        exit 1
    fi

    echo "   OK: ${label}"
}

get_latest_certificate_artifacts() {
    docker exec aimuza-db psql -U aimuza -d aimuza -t -A -F '|' -c \
        "SELECT COALESCE(registry_url, ''),
                COALESCE(certificate_url, ''),
                COALESCE(pdf_url, ''),
                COALESCE(blockchain_proof_url, ''),
                COALESCE(blockchain_proof_path, '')
         FROM public.track_deposits
         WHERE status = 'completed'
           AND (certificate_url IS NOT NULL OR pdf_url IS NOT NULL)
         ORDER BY completed_at DESC NULLS LAST, created_at DESC
         LIMIT 1;" | tr -d '\r'
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
echo "🧪 Шаг 8: Post-deploy smoke..."
assert_public_url "https://aimuza.ru/" "Главная"
assert_public_url "https://www.aimuza.ru/" "WWW домен"
assert_public_url "https://aimuza.ru/health" "Health endpoint"
assert_public_url "https://aimuza.ru/functions/v1/maintenance-status" "Maintenance status"

if [ -f "/etc/letsencrypt/live/aimuza.ru/fullchain.pem" ]; then
    if ! openssl x509 -in /etc/letsencrypt/live/aimuza.ru/fullchain.pem -noout -checkend 1209600 >/dev/null; then
        echo "❌ SSL-сертификат истекает меньше чем через 14 дней"
        exit 1
    fi
    echo "   OK: SSL-сертификат действителен более 14 дней"
fi

if [ "$(docker inspect aimuza-gotenberg --format '{{.State.Status}}')" != "running" ]; then
    echo "❌ aimuza-gotenberg не запущен после деплоя"
    exit 1
fi

curl -fsS http://127.0.0.1:3010/health >/dev/null
echo "   OK: Gotenberg health"

latest_artifacts="$(get_latest_certificate_artifacts)"
if [ -n "$latest_artifacts" ]; then
    IFS='|' read -r registry_url html_url pdf_url proof_url proof_path <<< "$latest_artifacts"

    if [ -n "$registry_url" ]; then
        assert_public_url "$registry_url" "Registry URL"
    fi

    if [ -n "$html_url" ] && [ -n "$registry_url" ]; then
        assert_html_contains "$html_url" "$registry_url" "HTML сертификат"
    elif [ -n "$html_url" ]; then
        assert_public_url "$html_url" "HTML сертификат"
    fi

    if [ -n "$pdf_url" ]; then
        assert_content_type "$pdf_url" "application/pdf" "PDF сертификат"
    fi

    if [ -n "$proof_url" ]; then
        assert_public_url "$proof_url" "Proof URL"
    fi

    if [ -n "$proof_path" ]; then
        if ! docker exec aimuza-api sh -lc "test -s \"/opt/aimuza/data/uploads/certificates/$proof_path\""; then
            echo "❌ Proof-файл отсутствует или пустой: $proof_path"
            exit 1
        fi
        echo "   OK: Proof-файл на диске"
    fi
else
    echo "   ⚠ Нет завершённых депонирований для smoke-проверки сертификатов"
fi

echo ""
echo "🧹 Шаг 9: Очистка старых образов..."
docker image prune -f

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         ✅ Деплой завершён!              ║"
echo "║   Сайт: https://aimuza.ru               ║"
echo "║   Health: https://aimuza.ru/health       ║"
echo "╚══════════════════════════════════════════╝"
