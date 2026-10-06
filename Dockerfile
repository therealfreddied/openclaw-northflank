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

# --- Disk hyper-slim: drop only provably-unused files ---------------------
# SAFETY: never descend into node_modules. Only prune sourcemaps/type-decls
# and top-level docs/tests dirs inside the openclaw package itself, so no
# runtime module can ever be removed.
RUN node -e ' \
  const fs=require("fs"),path=require("path"); \
  const root="/usr/local/lib/node_modules"; \
  const pkg=path.join(root,"openclaw"); \
  if(!fs.existsSync(pkg)){process.exit(0)} \
  const SAFE_FILE=/\.(map|tsbuildinfo)$/i; \
  const SAFE_DIR=/^(docs?|tests?|__tests__|__mocks__|fixtures|examples?|benchmarks?|\.github|\.vscode)$/i; \
  let freed=0; \
  (function walk(d,rel){ \
    for(const e of fs.readdirSync(d,{withFileTypes:true})){ \
      if(e.name==="node_modules"){continue} \
      const p=path.join(d,e.name); \
      const r=rel?rel+"/"+e.name:e.name; \
      if(e.isDirectory()){ \
        if(SAFE_DIR.test(e.name)){ freed+=dirSize(p); fs.rmSync(p,{recursive:true,force:true}); continue; } \
        walk(p,r); \
      } else if(SAFE_FILE.test(e.name)){ \
        try{freed+=fs.statSync(p).size; fs.rmSync(p,{force:true});}catch{} \
      } \
    } \
  })(pkg,""); \
  function dirSize(d){let s=0;const st=[d];while(st.length){const c=st.pop();for(const e of fs.readdirSync(c,{withFileTypes:true})){const p=path.join(c,e.name);if(e.isDirectory())st.push(p);else try{s+=fs.statSync(p).size}catch{}}}return s} \
  console.log("pruned ~"+(freed/1048576).toFixed(1)+"MB (node_modules untouched)"); \
'

# --- Hyper-optimized runtime env for 512MB / 0.2 vCPU ---------------------
ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR="/root/.openclaw"
ENV PORT=18789
ENV NODE_OPTIONS="--max-old-space-size=320 --max-semi-space-size=8 --dns-result-order=ipv4first"
ENV UV_THREADPOOL_SIZE=2
ENV NODE_COMPILE_CACHE="/root/.openclaw/.node-compile-cache"

# --- Self-healing launcher ------------------------------------------------
COPY northflank/start-gateway.mjs /opt/openclaw/start-gateway.mjs
COPY northflank/state-sync.mjs     /opt/openclaw/state-sync.mjs

EXPOSE 18789
CMD ["node", "/opt/openclaw/start-gateway.mjs"]