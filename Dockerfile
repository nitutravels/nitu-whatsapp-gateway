FROM devlikeapro/waha:noweb-arm-2026.7.1

LABEL org.opencontainers.image.source="https://github.com/nitutravels/nitu-whatsapp-gateway" \
      org.opencontainers.image.description="Nitu Travels WAHA Core NOWEB ARM64 gateway" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --chmod=0755 docker/waha-entrypoint.sh /usr/local/bin/nitu-waha-entrypoint
COPY docker/nitu-waha-supervisor.mjs /usr/local/lib/nitu-waha-supervisor.mjs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=8s --start-period=90s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

# Preserve the official WAHA command and delegate to its original entrypoint
# after mapping the existing Oracle gateway secrets to WAHA variables.
ENTRYPOINT ["/usr/local/bin/nitu-waha-entrypoint"]
