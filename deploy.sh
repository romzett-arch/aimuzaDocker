#!/bin/bash
# ═══════════════════════════════════════════════
# AI Planet Sound — Production Deploy
# Запуск на сервере: cd /opt/aimuza/deploy && bash deploy.sh
# Маршрут: Docker Hub → Сервер
# ═══════════════════════════════════════════════

set -e

COMPOSE_FILE="docker-compose.prod.yml"

echo "╔══════════════════════════════════════════╗"
echo "║   AI Planet Sound — Production Deploy    ║"
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
echo "🔄 Шаг 5: Перезагрузка Nginx..."
nginx -t && nginx -s reload
echo "✅ Nginx перезагружен"

echo ""
echo "🧹 Шаг 6: Очистка старых образов..."
docker image prune -f

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         ✅ Деплой завершён!              ║"
echo "║   Сайт: https://aimuza.ru               ║"
echo "║   Health: https://aimuza.ru/health       ║"
echo "╚══════════════════════════════════════════╝"
