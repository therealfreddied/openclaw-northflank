FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends     curl     ca-certificates     git     tar     sqlite3     && rm -rf /var/lib/apt/lists/*

WORKDIR /root/.openclaw

RUN npm install -g openclaw@latest --omit=dev

ENV NODE_OPTIONS="--max-old-space-size=384"
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 18789

CMD ["/start.sh"]
