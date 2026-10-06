#!/usr/bin/env bash
#
# OpenClaw + 9router — Northflank container entrypoint
# Self-healing, crash-proof supervisor for the free/always-on tier.
#
set -u

echo "[*] Initializing OpenClaw + 9router Stack on Northflank..."

mkdir -p /root/.9router
mkdir -p /root/.openclaw/workspace
mkdir -p /var/log/supervisor

# ---------------------------------------------------------------------------
# 1. Configure 9router (provider key pool from env, if supplied)
# ---------------------------------------------------------------------------
node -e '
const fs = require("fs");
const raw = process.env.GEMINI_KEYS || process.env.GEMINI_API_KEY || "";
const keys = raw.replace(/;/g, ",").split(",").map(k => k.trim()).filter(Boolean);
const config = {
  port: 20128,
  host: "0.0.0.0",
  providers: {
    gemini: {
      apiKeys: keys.length > 0 ? keys : [],
      strategy: "round-robin",
      retryOn429: true
    }
  }
};
fs.mkdirSync("/root/.9router", { recursive: true });
fs.writeFileSync("/root/.9router/config.json", JSON.stringify(config, null, 2));
console.log(`Configured 9router on 0.0.0.0:20128 with ${keys.length} key(s).`);
' || true

# ---------------------------------------------------------------------------
# 2. Resolve the 9router standalone server entrypoint
# ---------------------------------------------------------------------------
NPM_GLOBAL_ROOT="$(npm root -g 2>/dev/null || echo /usr/local/lib/node_modules)"
if [ -f "${NPM_GLOBAL_ROOT}/9router/app/custom-server.js" ]; then
  NINE_ROUTER_ENTRY="${NPM_GLOBAL_ROOT}/9router/app/custom-server.js"
elif [ -f "${NPM_GLOBAL_ROOT}/9router/app/server.js" ]; then
  NINE_ROUTER_ENTRY="${NPM_GLOBAL_ROOT}/9router/app/server.js"
else
  NINE_ROUTER_ENTRY="/usr/local/lib/node_modules/9router/app/server.js"
fi
NINE_ROUTER_APP_DIR="$(dirname "${NINE_ROUTER_ENTRY}")"
echo "[*] 9router entrypoint: ${NINE_ROUTER_ENTRY}"

# ---------------------------------------------------------------------------
# 3. Resolve OpenClaw gateway auth token
# ---------------------------------------------------------------------------
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  AUTH_TOKEN="${GATEWAY_TOKEN}"
else
  AUTH_TOKEN="$(node -e 'console.log(require("crypto").randomBytes(16).toString("hex"))')"
fi

echo "================================================================"
echo "  OPENCLAW GATEWAY AUTH TOKEN: ${AUTH_TOKEN}"
echo "  (set env GATEWAY_TOKEN to pin this value)"
echo "================================================================"

# ---------------------------------------------------------------------------
# 4. Write OpenClaw config (loopback-wired to local 9router)
# ---------------------------------------------------------------------------
OMNI_KEY="${NULLROUTE_API_KEY:-}"
cat > /root/.openclaw/openclaw.json << EOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": { "mode": "token", "token": "${AUTH_TOKEN}" }
  },
  "agents": {
    "defaults": {
      "model": "router/gemini-2.5-flash",
      "workspace": "/root/.openclaw/workspace"
    }
  },
  "models": {
    "providers": {
      "router": {
        "baseUrl": "http://127.0.0.1:20128/v1",
        "api": "openai-completions",
        "apiKey": "local-9router",
        "models": [
          { "id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash (9router)", "contextWindow": 1048576, "maxTokens": 32768, "input": ["text", "image"] },
          { "id": "gemini-2.5-pro",   "name": "Gemini 2.5 Pro (9router)",   "contextWindow": 1048576, "maxTokens": 32768, "input": ["text", "image"] },
          { "id": "gemini-2.0-flash", "name": "Gemini 2.0 Flash (9router)", "contextWindow": 1048576, "maxTokens": 32768, "input": ["text", "image"] }
        ]
      }
    }
  },
  "mcp": {
    "servers": {
      "search":  { "url": "https://api.nullroute.lol/search/mcp", "transport": "streamable-http", "headers": { "Authorization": "Bearer ${OMNI_KEY}" } },
      "memory":  { "url": "https://api.nullroute.lol/memory/mcp", "transport": "streamable-http", "headers": { "Authorization": "Bearer ${OMNI_KEY}" } },
      "crawl":   { "url": "https://api.nullroute.lol/crawl/mcp",  "transport": "streamable-http", "headers": { "Authorization": "Bearer ${OMNI_KEY}" } },
      "context": { "url": "https://api.nullroute.lol/docs/mcp",   "transport": "streamable-http", "headers": { "Authorization": "Bearer ${OMNI_KEY}" } }
    }
  }
}
EOF

# ---------------------------------------------------------------------------
# 5. Supervisor — restart-on-crash for BOTH processes (self-healing, 24/7)
# ---------------------------------------------------------------------------
supervise() {
  local name="$1"; shift
  local log="/var/log/supervisor/${name}.log"
  while true; do
    echo "[supervisor] starting ${name} at $(date -u +%FT%TZ)" >> "${log}"
    "$@" >> "${log}" 2>&1
    local code=$?
    echo "[supervisor] ${name} exited (code ${code}) — restarting in 3s" >> "${log}"
    sleep 3
  done
}

echo "[*] Launching 9router under supervisor (0.0.0.0:20128)..."
cd "${NINE_ROUTER_APP_DIR}"
PORT=20128 HOSTNAME=0.0.0.0 NODE_OPTIONS="--max-old-space-size=160" \
  supervise "9router" node "${NINE_ROUTER_ENTRY}" &
cd /root

# Give 9router a moment to bind before OpenClaw starts dialing it
sleep 5

echo "[*] Launching OpenClaw Gateway under supervisor (0.0.0.0:18789)..."
export NODE_OPTIONS="--max-old-space-size=256"
supervise "openclaw" openclaw gateway run --port 18789 --bind lan --auth token --token "${AUTH_TOKEN}" &

# ---------------------------------------------------------------------------
# 6. Keep the container alive; exit if the supervisor loop ever dies
# ---------------------------------------------------------------------------
wait -n
echo "[*] Supervisor parent exited — handing off to container restart policy"
wait
