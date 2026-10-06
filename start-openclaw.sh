#!/usr/bin/env bash
# OpenClaw gateway — single-container Northflank entrypoint (self-healing, 24/7)
set -u
log() { echo "[*] $*"; }

mkdir -p /root/.openclaw/workspace /var/log/supervisor

# Model routing: point at your existing NullRoute/OmniRoute endpoint.
# Override with ROUTER_BASE_URL + ROUTER_API_KEY env vars on the service.
ROUTER_BASE_URL="${ROUTER_BASE_URL:-https://api.nullroute.lol/v1}"
ROUTER_API_KEY="${ROUTER_API_KEY:-local-router}"

if [ -n "${GATEWAY_TOKEN:-}" ]; then
  AUTH_TOKEN="${GATEWAY_TOKEN}"
else
  AUTH_TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')"
fi

printf '%s\n' "================================================================"
printf '  OPENCLAW GATEWAY AUTH TOKEN: %s\n' "${AUTH_TOKEN}"
printf '%s\n' "  (set env GATEWAY_TOKEN to pin this value)"
printf '%s\n' "================================================================"

# Public hostname for allowedOrigins (override via PUBLIC_HOST)
PUBLIC_HOST="${PUBLIC_HOST:-claw--openclaw--q2728nnx75yc.code.run}"

# MCP bearer token for the NullRoute suites (override via NULLROUTE_KEY)
NULLROUTE_KEY="${NULLROUTE_KEY:-}"

cat > /root/.openclaw/openclaw.json <<JSON
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "controlUi": { "allowedOrigins": ["https://${PUBLIC_HOST}"] },
    "auth": { "mode": "token", "token": "${AUTH_TOKEN}" }
  },
  "agents": {
    "defaults": { "model": "router/nullroute-smart", "workspace": "/root/.openclaw/workspace" }
  },
  "models": {
    "providers": {
      "router": {
        "baseUrl": "${ROUTER_BASE_URL}",
        "api": "openai-completions",
        "apiKey": "${ROUTER_API_KEY}",
        "models": [
          { "id": "nullroute/smart", "name": "NullRoute Smart (Claude Sonnet)", "contextWindow": 1048576, "maxTokens": 32768, "input": ["text","image"] },
          { "id": "nullroute/coder", "name": "NullRoute Coder (DeepSeek)", "contextWindow": 1048576, "maxTokens": 32768, "input": ["text","image"] }
        ]
      }
    }
  },
  "mcp": {
    "servers": {
      "search":  { "url": "https://api.nullroute.lol/search/mcp", "transport": "streamable-http", "headers": { "Authorization": "Bearer ${NULLROUTE_KEY}" } },
      "memory":  { "url": "https://api.nullroute.lol/memory/mcp", "transport": "streamable-http", "headers": { "Authorization": "Bearer ${NULLROUTE_KEY}" } },
      "crawl":   { "url": "https://api.nullroute.lol/crawl/mcp",  "transport": "streamable-http", "headers": { "Authorization": "Bearer ${NULLROUTE_KEY}" } },
      "context": { "url": "https://api.nullroute.lol/docs/mcp",   "transport": "streamable-http", "headers": { "Authorization": "Bearer ${NULLROUTE_KEY}" } }
    }
  }
}
JSON

supervise() {
  name="$1"; shift
  logf="/var/log/supervisor/${name}.log"
  while true; do
    echo "[supervisor] starting ${name} at $(date -u +%FT%TZ)" >>"${logf}"
    "$@" >>"${logf}" 2>&1
    echo "[supervisor] ${name} exited (code $?) — restarting in 3s" >>"${logf}"
    sleep 3
  done
}

log "Launching OpenClaw Gateway on 0.0.0.0:18789 (router=${ROUTER_BASE_URL})"
export NODE_OPTIONS="--max-old-space-size=384"
supervise openclaw openclaw gateway run --port 18789 --bind lan --auth token --token "${AUTH_TOKEN}" &
wait
