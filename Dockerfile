FROM node:24-slim

# --- Minimal runtime deps -------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      git \
      tar \
      procps \
      sqlite3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# --- OpenClaw (stock install, no pruning — correctness first) -------------
RUN npm install -g openclaw@latest --omit=dev --no-audit --no-fund

# --- Runtime env tuned for 512MB / 0.2 vCPU -------------------------------
ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789
ENV UV_THREADPOOL_SIZE=2

# --- Self-healing launcher ------------------------------------------------
COPY northflank/start-gateway.mjs /opt/openclaw/start-gateway.mjs
COPY northflank/state-sync.mjs     /opt/openclaw/state-sync.mjs

EXPOSE 18789
CMD ["node", "/opt/openclaw/start-gateway.mjs"]