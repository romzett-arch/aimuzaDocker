FROM denoland/deno:1.40.0

WORKDIR /app

# Предзагружаем npm-модули которые нужны функциям
RUN deno eval "import nodemailer from 'npm:nodemailer@6.9.10'; console.log('nodemailer cached');" 2>/dev/null || \
    deno eval "import nodemailer from 'npm:nodemailer@6.9.10'; console.log('nodemailer cached');" 2>/dev/null || \
    echo "nodemailer cache attempt done"

# Копируем код функций
COPY . .

EXPOSE 8081

CMD ["run", "--allow-all", "--unstable", "server.ts"]
