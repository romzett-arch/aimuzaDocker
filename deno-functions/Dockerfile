# Stage 1: grab Deno binary
FROM denoland/deno:1.40.0 AS deno-bin

# Stage 2: runtime on bookworm (OpenSSL 3.0.x — trixie's 3.5.4 breaks HTTPS uploads >10KB)
FROM debian:bookworm-slim

COPY --from=deno-bin /usr/bin/deno /usr/bin/deno

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Копируем код функций
COPY . .

# Сервер импортирует std и Supabase до открытия порта. Кэшируем этот граф при
# сборке, чтобы запуск контейнера не зависел от доступа прод-сервера к deno.land.
RUN deno cache --import-map=import_map.json server.ts

EXPOSE 8081

CMD ["/usr/bin/deno", "run", "--allow-all", "--unstable", "--import-map=import_map.json", "server.ts"]
