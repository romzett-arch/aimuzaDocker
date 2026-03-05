#!/bin/bash
# ═══════════════════════════════════════════════
# AIMUZA — Production Deploy
# Запуск на сервере: cd /opt/aimuza/deploy && bash deploy.sh
# Маршрут: Docker Hub → Сервер
# ═══════════════════════════════════════════════

set -e

COMPOSE_FILE="docker-compose.prod.yml"

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

echo ""
echo "📥 Шаг 1: Pull свежих образов с Docker Hub..."
docker compose -f "$COMPOSE_FILE" pull

echo ""
echo "🚀 Шаг 2: Перезапуск контейнеров..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "⏳ Шаг 3: Ожидание healthcheck (15 сек)..."
sleep 15

echo ""
echo "📊 Шаг 4: Статус контейнеров:"
docker compose -f "$COMPOSE_FILE" ps

echo ""
echo "📄 Шаг 5: Синхронизация nginx config..."
if [ -f "nginx/aimuza.ru.prod.conf" ]; then
    cp nginx/aimuza.ru.prod.conf /etc/nginx/sites-available/aimuza.ru
    ln -sf /etc/nginx/sites-available/aimuza.ru /etc/nginx/sites-enabled/aimuza.ru
    echo "   nginx/aimuza.ru.prod.conf → sites-available + sites-enabled (symlink)"
else
    echo "   ⚠ nginx/aimuza.ru.prod.conf не найден, пропуск"
fi

echo ""
echo "🔄 Шаг 6: Перезагрузка Nginx..."
nginx -t && nginx -s reload
echo "✅ Nginx перезагружен"

echo ""
echo "🧹 Шаг 7: Очистка старых образов..."
docker image prune -f

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         ✅ Деплой завершён!              ║"
echo "║   Сайт: https://aimuza.ru               ║"
echo "║   Health: https://aimuza.ru/health       ║"
echo "╚══════════════════════════════════════════╝"
