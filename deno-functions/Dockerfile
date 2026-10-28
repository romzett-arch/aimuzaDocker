# Stage 1: grab Deno binary
FROM denoland/deno@sha256:a0d88a7fcbd44f062cba2748e19df67d30290ad12aa203c7c1e0b12462c483f0 AS deno-bin

# Build/cache stage. Package managers and curl do not enter the runtime.
FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS cached

COPY --from=deno-bin /usr/bin/deno /usr/bin/deno

WORKDIR /app
ENV DENO_DIR=/deno-dir DENO_NO_UPDATE_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Копируем код функций
COPY . .

# Сервер импортирует std и Supabase до открытия порта. Кэшируем этот граф при
# сборке, чтобы запуск контейнера не зависел от доступа прод-сервера к deno.land.
RUN deno cache --frozen --lock=deno.lock --import-map=import_map.json server.ts functions/*/index.ts

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:3ee00291cf386ec52a552e6a858d555debd74776eb4bfa53fa3df2cd6677515e
COPY --from=cached /usr/bin/deno /usr/bin/deno
COPY --from=cached --chown=65532:65532 /deno-dir /deno-dir
COPY --from=cached --chown=65532:65532 /app /app
WORKDIR /app
ENV DENO_DIR=/deno-dir DENO_NO_UPDATE_CHECK=1
USER 65532:65532

EXPOSE 8081

CMD ["/usr/bin/deno", "run", "--cached-only", "--frozen", "--lock=deno.lock", "--allow-env", "--allow-net", "--allow-read=/app", "--import-map=import_map.json", "server.ts"]
