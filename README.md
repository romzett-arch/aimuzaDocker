# AI Planet Sound — Docker Deployment

Инфраструктура деплоя: API, Deno Edge Functions, PostgreSQL, FFmpeg, Realtime, Radio.

## Быстрый старт

```bash
cp .env.example .env
# Заполнить .env (DB_PASSWORD, JWT_SECRET, ANON_KEY, SUNO_API_KEY, ...)
docker compose up -d
```

## Документация

- [aimuza.ru](https://github.com/romzett-arch/aimuza.ru) — основной репо: docs/BACKEND-ASSEMBLY-GUIDE.md, docs/WORKFLOW.md

## Маршрут деплоя

```
Локалка → push.sh → Docker Hub (romzett/aimuza-*) → Сервер (217.199.254.170)
```

## Сервисы

| Сервис | Порт | Назначение |
|--------|------|------------|
| api | 3000 | Node.js API (auth, rest, rpc, storage, functions) |
| deno-functions | 8081 | Edge Functions |
| db | 5432 | PostgreSQL |
| ffmpeg-api | 3001 | FFmpeg обработка |
| realtime | 4000 | WebSocket |
| radio | — | Radio queue worker |
