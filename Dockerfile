FROM node:24-slim

# Minimal system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    tar \
    procps \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# OpenClaw only — no 9router (single-container deployment)
RUN npm install -g openclaw@latest --omit=dev

ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789

COPY start-openclaw.sh /start-openclaw.sh
RUN chmod +x /start-openclaw.sh

EXPOSE 18789
CMD ["/start-openclaw.sh"]
