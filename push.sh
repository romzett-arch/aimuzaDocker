#!/bin/bash
# ═══════════════════════════════════════════════
# AI Planet Sound — Push images to Docker Hub
# Запуск: cd deploy && bash push.sh
# Маршрут: Локалка → Docker Hub → Сервер
# ═══════════════════════════════════════════════

set -e

REGISTRY="romzett"
IMAGES=("aimuza-api" "aimuza-frontend" "aimuza-realtime" "aimuza-ffmpeg" "aimuza-radio" "aimuza-deno")
LOCAL_NAMES=("deploy-api" "deploy-frontend" "deploy-realtime" "deploy-ffmpeg-api" "deploy-radio" "deploy-deno-functions")

echo "╔══════════════════════════════════════════╗"
echo "║   Push to Docker Hub: $REGISTRY          ║"
echo "╚══════════════════════════════════════════╝"

# Сборка
echo ""
echo "📦 Шаг 1: Сборка образов..."
docker compose build

# Тегирование и push
echo ""
echo "🚀 Шаг 2: Тегирование и push..."
for i in "${!IMAGES[@]}"; do
    local_name="${LOCAL_NAMES[$i]}"
    remote_name="${REGISTRY}/${IMAGES[$i]}"
    echo "  → ${local_name}:latest → ${remote_name}:latest"
    docker tag "${local_name}:latest" "${remote_name}:latest"
    docker push "${remote_name}:latest"
done

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✅ Все образы на Docker Hub!           ║"
echo "║   Теперь на сервере: bash deploy.sh      ║"
echo "╚══════════════════════════════════════════╝"
