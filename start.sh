#!/usr/bin/env bash
#
# OpenClaw + 9router - Northflank container entrypoint
# Crash-proof, self-healing supervisor for the always-on tier.
#
set -u

log() { echo "[*] $*"; }

STACK_MODE="${STACK_MODE:-both}"

log "Initializing stack on Northflank (mode=${STACK_MODE})..."

mkdir -p /root/.9router
mkdir -p /root/.openclaw/workspace
mkdir -p /var/log/supervisor

# --- Auth token (env-pinned, or generated once and persisted) --------------
TOKEN_FILE=/root/.openclaw/.gateway_token
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  AUTH_TOKEN="${GATEWAY_TOKEN:-}"
elif [ -f "${TOKEN_FILE}" ]; then
  AUTH_TOKEN="$(cat ${TOKEN_FILE})"
else
  AUTH_TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))')"
  printf '%s' "${AUTH_TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
fi

printf '%s\n' "================================================================"
printf '  OPENCLAW GATEWAY AUTH TOKEN: %s\n' "${AUTH_TOKEN}"
printf '%s\n' "  (set env GATEWAY_TOKEN to pin this value)"
printf '%s\n' "================================================================"

# --- 9router (only in both mode) -------------------------------------------
if [ "${STACK_MODE}" = "both" ]; then
  node -e '
  const fs = require("fs");
  const raw = process.env.GEMINI_KEYS || process.env.GEMINI_API_KEY || "";
  const keys = raw.replace(/;/g, ",").split(",").map(k => k.trim()).filter(Boolean);
  const config = {
    port: 20128,
    host: "0.0.0.0",
    providers: { gemini: { apiKeys: keys, strategy: "round-robin", retryOn429: true } }
  };
  fs.mkdirSync("/root/.9router", { recursive: true });
  fs.writeFileSync("/root/.9router/config.json", JSON.stringify(config, null, 2));
  console.log("Configured 9router on 0.0.0.0:20128 with " + keys.length + " key(s).");
  ' || true

  NPM_GLOBAL_ROOT="$(npm root -g 2>/dev/null || echo /usr/local/lib/node_modules)"
  if [ -f "${NPM_GLOBAL_ROOT}/9router/app/custom-server.js" ]; then
    NINE_ROUTER_ENTRY="${NPM_GLOBAL_ROOT}/9router/app/custom-server.js"
  elif [ -f "${NPM_GLOBAL_ROOT}/9router/app/server.js" ]; then
    NINE_ROUTER_ENTRY="${NPM_GLOBAL_ROOT}/9router/app/server.js"
  else
    NINE_ROUTER_ENTRY="/usr/local/lib/node_modules/9router/app/server.js"
  fi
  NINE_ROUTER_APP_DIR="$(dirname ${NINE_ROUTER_ENTRY})"
  log "9router entrypoint: ${NINE_ROUTER_ENTRY}"
fi

# --- OpenClaw config --------------------------------------------------------
PUBLIC_HOST="claw--openclaw-stack--q2728nnx75yc.code.run"

if [ "${STACK_MODE}" = "both" ]; then
  cat > /root/.openclaw/openclaw.json <<EOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "controlUi": { "allowedOrigins": ["https://${PUBLIC_HOST}"] },
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
  }
}
EOF
else
  cat > /root/.openclaw/openclaw.json <<EOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "controlUi": { "allowedOrigins": ["https://${PUBLIC_HOST}"] },
    "auth": { "mode": "token", "token": "${AUTH_TOKEN}" }
  },
  "agents": {
    "defaults": { "workspace": "/root/.openclaw/workspace" }
  }
}
EOF
fi

# --- Supervisor (restart-on-crash, stdout tee) ------------------------------
supervise() {
  name="${1}"; shift
  logf="/var/log/supervisor/${name}.log"
  while true; do
    echo "[supervisor] starting ${name} at $(date -u +%FT%TZ)" | tee -a "${logf}"
    "$@" 2>&1 | tee -a "${logf}"
    code="${PIPESTATUS[0]}"
    echo "[supervisor] ${name} exited (code ${code}) - restarting in 3s" | tee -a "${logf}"
    sleep 3
  done
}

if [ "${STACK_MODE}" = "both" ]; then
  log "Launching 9router under supervisor (0.0.0.0:20128)..."
  cd "${NINE_ROUTER_APP_DIR}"
  PORT=20128 HOSTNAME=0.0.0.0 NODE_OPTIONS="--max-old-space-size=128" \
    supervise 9router node "${NINE_ROUTER_ENTRY}" &
  cd /root
  sleep 6
fi

log "Launching OpenClaw Gateway under supervisor (0.0.0.0:18789)..."
export NODE_OPTIONS="--max-old-space-size=224"
supervise openclaw openclaw gateway --port 18789 --bind lan --allow-unconfigured &

# --- Port watchdog ----------------------------------------------------------
(
  sleep 60
  fails=0
  while true; do
    if curl -s -o /dev/null --max-time 10 http://127.0.0.1:18789/ ; then
      fails=0
    else
      fails=$((fails+1))
      echo "[watchdog] gateway probe failed (${fails}/5)" | tee -a /var/log/supervisor/watchdog.log
      if [ "${fails}" -ge 5 ]; then
        echo "[watchdog] gateway unresponsive - exiting for container restart" | tee -a /var/log/supervisor/watchdog.log
        exit 1
      fi
    fi
    sleep 30
  done
) &

wait -n
log "Supervisor parent exited - handing off to container restart policy"
wait
