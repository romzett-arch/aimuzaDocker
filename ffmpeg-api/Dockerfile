FROM node:20-alpine

RUN apk add --no-cache ffmpeg

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY server.js ./
RUN mkdir -p uploads output

EXPOSE 3001

CMD ["node", "server.js"]
