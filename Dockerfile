FROM devlikeapro/waha:noweb-2026.7.1

LABEL org.opencontainers.image.source="https://github.com/nitutravels/nitu-whatsapp-gateway" \
      org.opencontainers.image.description="Nitu Travels WAHA Core NOWEB x86-64 gateway" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --chmod=0755 docker/waha-entrypoint.sh /usr/local/bin/nitu-waha-entrypoint
COPY docker/nitu-waha-supervisor.mjs /usr/local/lib/nitu-waha-supervisor.mjs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=8s --start-period=90s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

# The wrapper maps the existing Oracle compose variables to WAHA and then
# delegates startup to WAHA's official /entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/nitu-waha-entrypoint"]
