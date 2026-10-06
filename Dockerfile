FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends     curl     ca-certificates     git     tar     sqlite3     procps     && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Install OpenClaw globally & install 9router
RUN npm install -g openclaw@latest --omit=dev &&     npm install -g 9router@latest --omit=dev

# Memory & Runtime Configuration (Caps heap to stay safely under 512MB RAM)
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 18789

CMD ["/start.sh"]
