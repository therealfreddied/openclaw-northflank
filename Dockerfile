FROM node:24-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    tar \
    sqlite3 \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Install OpenClaw globally & install 9router CLI
RUN npm install -g openclaw@latest --omit=dev && \
    npm install -g 9router@latest --omit=dev

# Environment setup
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 18789 20129

CMD ["/start.sh"]
