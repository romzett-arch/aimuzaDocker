# Stage 1: grab Deno binary
FROM denoland/deno:1.40.0 AS deno-bin

# Stage 2: runtime on bookworm (OpenSSL 3.0.x — trixie's 3.5.4 breaks HTTPS uploads >10KB)
FROM debian:bookworm-slim

COPY --from=deno-bin /usr/bin/deno /usr/bin/deno

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Предзагружаем npm-модули которые нужны функциям
RUN deno eval "import nodemailer from 'npm:nodemailer@6.9.10'; console.log('nodemailer cached');" 2>/dev/null || \
    deno eval "import nodemailer from 'npm:nodemailer@6.9.10'; console.log('nodemailer cached');" 2>/dev/null || \
    echo "nodemailer cache attempt done"

# Копируем код функций
COPY . .

EXPOSE 8081

CMD ["/usr/bin/deno", "run", "--allow-all", "--unstable", "server.ts"]
