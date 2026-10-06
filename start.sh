#!/usr/bin/env bash
set -e

echo "[*] Initializing 9router + OpenClaw unified free stack on Northflank..."

mkdir -p /root/.9router
mkdir -p /root/.openclaw/workspace

# 1. Configure 9router Gemini Key Pool using pure Node.js (no python dependency)
node -e '
const fs = require("fs");
const os = require("os");
const raw = process.env.GEMINI_KEYS || process.env.GEMINI_API_KEY || "";
const keys = raw.replace(/;/g, ",").split(",").map(k => k.trim()).filter(Boolean);

const config = {
  port: 20129,
  host: "0.0.0.0",
  providers: {
    gemini: {
      apiKeys: keys.length > 0 ? keys : ["AIzaSyDummyKeyReplaceInDashboard"],
      strategy: "round-robin",
      retryOn429: true
    }
  }
};

fs.mkdirSync("/root/.9router", { recursive: true });
fs.writeFileSync("/root/.9router/config.json", JSON.stringify(config, null, 2));
console.log(`Configured 9router on 0.0.0.0:20129 with ${keys.length} Gemini key(s).`);
'

# 2. Launch 9router in Background (Bound to 0.0.0.0:20129 for public dashboard & internal routing)
echo "[*] Launching 9router on 0.0.0.0:20129..."
NODE_OPTIONS="--max-old-space-size=96" 9router start --port 20129 --host 0.0.0.0 &
sleep 2

# 3. Configure OpenClaw Gateway
if [ -n "$GATEWAY_TOKEN" ]; then
  AUTH_TOKEN="$GATEWAY_TOKEN"
else
  AUTH_TOKEN=$(node -e 'console.log(require("crypto").randomBytes(16).toString("hex"))')
fi

cat << EOF > /root/.openclaw/openclaw.json
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${AUTH_TOKEN}"
    }
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
        "baseUrl": "http://127.0.0.1:20129/v1",
        "api": "openai-completions",
        "apiKey": "local-9router-token",
        "models": [
          {
            "id": "gemini-2.5-flash",
            "name": "Gemini 2.5 Flash (9router Key Pool)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "gemini-2.5-pro",
            "name": "Gemini 2.5 Pro (9router Key Pool)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "gemini-2.0-flash",
            "name": "Gemini 2.0 Flash (9router Key Pool)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          }
        ]
      },
      "omniroute": {
        "baseUrl": "https://api.nullroute.lol/v1",
        "api": "openai-completions",
        "apiKey": "sk-c4ff2e1075c20e63fa572bb2f5d9d6cc3091d9666ac5ab4f",
        "models": [
          {
            "id": "nullroute/smart",
            "name": "NullRoute Smart (Claude Sonnet 4.6)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "nullroute/coder",
            "name": "NullRoute Coder (DeepSeek-V4.1 Flash)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "nullroute/nullroute-coder:free",
            "name": "NullRoute Coder (Free Tier)",
            "contextWindow": 128000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "mcp": {
    "servers": {
      "search": {
        "url": "https://api.nullroute.lol/search/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer sk-c4ff2e1075c20e63fa572bb2f5d9d6cc3091d9666ac5ab4f" }
      },
      "memory": {
        "url": "https://api.nullroute.lol/memory/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer sk-c4ff2e1075c20e63fa572bb2f5d9d6cc3091d9666ac5ab4f" }
      },
      "crawl": {
        "url": "https://api.nullroute.lol/crawl/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer sk-c4ff2e1075c20e63fa572bb2f5d9d6cc3091d9666ac5ab4f" }
      },
      "context": {
        "url": "https://api.nullroute.lol/docs/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer sk-c4ff2e1075c20e63fa572bb2f5d9d6cc3091d9666ac5ab4f" }
      }
    }
  }
}
EOF

echo "[*] Launching OpenClaw Gateway on 0.0.0.0:18789 with auth token: ${AUTH_TOKEN}"
export NODE_OPTIONS="--max-old-space-size=256"
exec openclaw gateway --port 18789 --bind lan --allow-unconfigured
