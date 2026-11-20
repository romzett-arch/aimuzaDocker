FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

WORKDIR /app
RUN mkdir -p /app/state && chown node:node /app/state
COPY --chown=node:node *.mjs ./
COPY russian-trusted-root.crt /app/russian-trusted-root.crt
ENV NODE_EXTRA_CA_CERTS=/app/russian-trusted-root.crt
USER node
EXPOSE 3215
CMD ["node", "index.mjs"]
