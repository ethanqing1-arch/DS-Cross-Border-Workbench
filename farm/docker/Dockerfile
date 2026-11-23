FROM --platform=linux/amd64 docker.m.daocloud.io/library/debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
    libcairo2 libasound2 libxshmfence1 libx11-xcb1 libxcb1 libxext6 libxi6 \
    fonts-liberation fonts-noto-cjk xvfb procps ca-certificates socat \
 && rm -rf /var/lib/apt/lists/*

COPY tree/ungoogled-chromium-150.0.7871.186-1-x86_64_linux /opt/chrome
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh && chmod 4755 /opt/chrome/chrome_sandbox 2>/dev/null || true

ENV DISPLAY=:99
EXPOSE 9333 9334
ENTRYPOINT ["/entry.sh"]
