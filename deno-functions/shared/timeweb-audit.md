# Проверка расхода токенов Timeweb Agent

Этот файл — инструкция для агента AIMUZA. Использовать, когда пользователь спрашивает:

- «Что делает Timeweb Agent?»
- «Почему расходуются токены, когда на сайте никого нет?»
- «Какая функция потратила токены?»
- «Сколько токенов было потрачено за период?»

Перед любыми действиями обязательно полностью прочитать `C:\Cursor\aimuza.ru\docs\WORKFLOW.md` и выполнить предусмотренные им проверки.

## Где хранится аудит

- Таблица PostgreSQL: `public.ai_request_logs`.
- Миграция: `supabase/migrations/20260713050000_ai_request_logs.sql`.
- Код журналирования: `deploy/deno-functions/shared/timeweb-audit.ts`.
- Журнал создаётся **до** обращения к Timeweb и обновляется после ответа.
- Промпты, ответы модели, ключи и персональные данные не сохраняются.

## Быстрая проверка локально

Выполнить из `C:\Cursor\aimuza.ru`:

```powershell
docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c "SELECT created_at, source, action, reason, model, prompt_tokens, completion_tokens, total_tokens, duration_ms, http_status, status, error FROM public.ai_request_logs ORDER BY created_at DESC LIMIT 100;"
```

Суммарный расход по функциям за последние 7 дней:

```powershell
docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c "SELECT source, action, count(*) AS requests, coalesce(sum(prompt_tokens), 0) AS prompt_tokens, coalesce(sum(completion_tokens), 0) AS completion_tokens, coalesce(sum(total_tokens), 0) AS total_tokens, round(avg(duration_ms)) AS avg_duration_ms, count(*) FILTER (WHERE status = 'failed') AS failed FROM public.ai_request_logs WHERE created_at >= now() - interval '7 days' GROUP BY source, action ORDER BY total_tokens DESC, requests DESC;"
```

Почасовая проверка расхода без посетителей:

```powershell
docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c "SELECT date_trunc('hour', created_at) AS hour, count(*) AS requests, coalesce(sum(total_tokens), 0) AS total_tokens, string_agg(DISTINCT source, ', ' ORDER BY source) AS sources FROM public.ai_request_logs WHERE created_at >= now() - interval '48 hours' GROUP BY 1 ORDER BY 1 DESC;"
```

Зависшие записи, для которых запрос начался, но не завершился:

```powershell
docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c "SELECT * FROM public.ai_request_logs WHERE status = 'started' AND created_at < now() - interval '10 minutes' ORDER BY created_at DESC;"
```

## Проверка на сервере

Проверка выполняется по SSH без изменения данных:

```powershell
ssh root@217.199.254.170 "docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c \"SELECT created_at, source, action, reason, model, prompt_tokens, completion_tokens, total_tokens, duration_ms, http_status, status, error FROM public.ai_request_logs ORDER BY created_at DESC LIMIT 100;\""
```

Сводка за последние 7 дней:

```powershell
ssh root@217.199.254.170 "docker exec aimuza-db psql -U aimuza -d aimuza -P pager=off -c \"SELECT source, action, count(*) AS requests, coalesce(sum(prompt_tokens), 0) AS prompt_tokens, coalesce(sum(completion_tokens), 0) AS completion_tokens, coalesce(sum(total_tokens), 0) AS total_tokens, count(*) FILTER (WHERE status = 'failed') AS failed FROM public.ai_request_logs WHERE created_at >= now() - interval '7 days' GROUP BY source, action ORDER BY total_tokens DESC, requests DESC;\""
```

Если сервер отвечает `relation "public.ai_request_logs" does not exist`, аудит ещё не задеплоен или миграция не применена. Не исправлять сервер вручную: следовать процессу деплоя из `WORKFLOW.md` и убедиться, что миграция применена штатным deploy-скриптом.

## Как интерпретировать записи

| Поле | Значение |
|---|---|
| `source` | Deno-функция, инициировавшая обращение |
| `action` | Что именно агент должен был сделать |
| `reason` | Почему обращение было запущено |
| `request_chars` | Размер сообщений без сохранения их текста |
| `prompt_tokens` | Входные токены по данным Timeweb |
| `completion_tokens` | Выходные токены по данным Timeweb |
| `total_tokens` | Общий расход по данным Timeweb |
| `status = started` | Запрос начался, но итог ещё не записан |
| `status = completed` | Timeweb успешно ответил |
| `status = failed` | Сетевая ошибка или неуспешный HTTP-статус |

Если поля токенов равны `NULL`, проверить `http_status` и `status`. Успешный ответ без `usage` означает, что Timeweb не вернул статистику токенов в теле конкретного ответа; в таком случае использовать `request_chars`, число запросов и данные панели Timeweb как вспомогательные показатели.

## Алгоритм ответа пользователю

1. Уточнить период, если он не указан; по умолчанию проверить последние 7 дней и отдельно последние 48 часов.
2. Получить сводку по `source` и `action`.
3. Найти часы расхода, когда пользователь считает сайт пустым.
4. Для этих часов показать конкретные `reason`, статусы и количество токенов.
5. Сопоставить записи с логами `aimuza-deno` и nginx только при необходимости.
6. Отдельно сообщить, если новых записей нет, а панель Timeweb продолжает показывать рост: возможна задержка статистики либо использование того же токена вне этого сервера.
7. Не выводить и не копировать значения `TIMEWEB_AGENT_TOKEN`, service-role ключей и callback-секретов.

## Текущие источники обращений

Аудит подключён к 16 источникам: классификация музыкальных треков, анализ и генерация текстов, метаданные, рекламный таргетинг, дистрибуция, форумный AI и автомодерация, QA, SEO, поддержка, antifraud и административный дайджест.

Основной ранее обнаруженный источник фонового расхода — `suno-callback / classify_generated_track`: классификация завершённого музыкального трека после callback внешнего сервиса. Наличие посетителей на сайте для такого обращения не требуется.
