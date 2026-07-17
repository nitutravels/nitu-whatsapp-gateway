FROM node:22-bookworm-slim AS dependencies

ENV NODE_ENV=production \
    PUPPETEER_SKIP_DOWNLOAD=true

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    python3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./

# The packaged lockfile was generated behind an isolated build registry.
# Rewrite only that registry prefix so GitHub Actions downloads the same
# integrity-pinned packages from npm's public registry.
RUN sed -i \
      's#https://packages.applied-caas-gateway1.internal.api.openai.org/artifactory/api/npm/npm-public/#https://registry.npmjs.org/#g' \
      package-lock.json \
  && npm ci --omit=dev \
  && npm cache clean --force

FROM node:22-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/nitutravels/nitu-whatsapp-gateway" \
      org.opencontainers.image.description="Nitu Travels WhatsApp linked-device gateway" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PUPPETEER_SKIP_DOWNLOAD=true \
    CHROME_PATH=/usr/bin/chromium

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    ca-certificates \
    dumb-init \
    fonts-liberation \
    fonts-noto-color-emoji \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json ./
COPY --from=dependencies /app/package-lock.json ./package-lock.json
COPY src ./src
COPY public ./public
RUN mkdir -p /data && chown -R node:node /app /data

USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
