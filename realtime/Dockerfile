FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force && rm -rf /usr/local/lib/node_modules/npm /opt/yarn*

COPY server.js channels.js connections.js security.js safe-logging.js ./
USER node

EXPOSE 4000

CMD ["node", "server.js"]
