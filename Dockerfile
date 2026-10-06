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

# --- OpenClaw (no 9router, single container) ------------------------------
RUN npm install -g openclaw@latest --omit=dev --no-audit --no-fund

# --- Disk hyper-slim: drop files the runtime never reads ------------------
# Protocol-inert: keeps dist/ runtime code, UI assets, manifests, bin/.
RUN node -e ' \
  const fs=require("fs"),path=require("path"); \
  const root=process.env.NPM_CONFIG_PREFIX||"/usr/local/lib/node_modules"; \
  const pkg=path.join(root,"openclaw"); \
  if(!fs.existsSync(pkg)){process.exit(0)} \
  let freed=0; \
  const FILE_RE=/\.(map|d\.ts|tsbuildinfo|md|mdx)$/i; \
  const DIR_RE=/(^|\/)(docs?|tests?|__tests__|__mocks__|fixtures|examples?|benchmarks?)(\/|$)/i; \
  (function walk(d){ \
    for(const e of fs.readdirSync(d,{withFileTypes:true})){ \
      const p=path.join(d,e.name); \
      if(e.isDirectory()){ if(DIR_RE.test(p.slice(pkg.length+1))){ fs.rmSync(p,{recursive:true,force:true}); continue; } walk(p); } \
      else if(FILE_RE.test(e.name)){ try{freed+=fs.statSync(p).size; fs.rmSync(p,{force:true});}catch{} } \
    } \
  })(pkg); \
  console.log("pruned ~"+(freed/1048576).toFixed(1)+"MB from openclaw"); \
'

# --- Hyper-optimized runtime env for 512MB / 0.2 vCPU ---------------------
ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789
# V8 heap ceilings (child gateway), small semi-space, tiny threadpool for 0.2 vCPU
ENV NODE_OPTIONS="--max-old-space-size=320 --max-semi-space-size=8 --dns-result-order=ipv4first"
ENV UV_THREADPOOL_SIZE=2
ENV NODE_COMPILE_CACHE="/root/.openclaw/.node-compile-cache"

# --- Self-healing launcher ------------------------------------------------
COPY northflank/start-gateway.mjs /opt/openclaw/start-gateway.mjs
COPY northflank/state-sync.mjs     /opt/openclaw/state-sync.mjs

EXPOSE 18789
CMD ["node", "/opt/openclaw/start-gateway.mjs"]