FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium xvfb x11vnc novnc websockify fluxbox supervisor socat \
    ca-certificates curl fonts-liberation fonts-noto-color-emoji dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data/profile /var/log/supervisor && chmod -R 777 /data
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 6080 9223
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
