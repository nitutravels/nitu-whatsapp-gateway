FROM node:22-bookworm-slim AS dependencies

ENV NODE_ENV=production

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY v2/package.json ./
RUN npm install --omit=dev --no-audit --no-fund \
  && npm cache clean --force

FROM node:22-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/nitutravels/nitu-whatsapp-gateway" \
      org.opencontainers.image.description="Nitu Travels durable Baileys WebSocket gateway" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=384"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    dumb-init \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY v2/package.json ./
COPY v2/src ./src
COPY v2/public ./public
RUN mkdir -p /data \
  && chown -R node:node /app /data

USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
