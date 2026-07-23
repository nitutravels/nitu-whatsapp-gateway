FROM node:22-bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY index.js ./
RUN python3 - <<'PY'
from pathlib import Path
p=Path('/app/index.js')
s=p.read_text()
old="app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});"
new="const server=app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});\nserver.on('upgrade',browserProxy.upgrade);"
if old in s:
    p.write_text(s.replace(old,new,1))
elif "server.on('upgrade',browserProxy.upgrade);" not in s:
    raise SystemExit('Expected NAMS listen statement not found')
PY
RUN mkdir -p /app/data /app/assets /app/config

EXPOSE 8080
CMD ["node", "index.js"]
