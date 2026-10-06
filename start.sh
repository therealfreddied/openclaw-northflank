#!/usr/bin/env bash
set -e

mkdir -p /root/.openclaw/workspace

if [ ! -f /root/.openclaw/openclaw.json ]; then
cat << 'EOF' > /root/.openclaw/openclaw.json
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "admin-openclaw-2026"
    }
  },
  "agents": {
    "defaults": {
      "model": "omniroute/antigravity/gemini-3.7-flash-medium",
      "workspace": "/root/.openclaw/workspace"
    }
  },
  "models": {
    "providers": {
      "omniroute": {
        "baseUrl": "https://api.nullroute.lol/v1",
        "api": "openai-completions",
        "apiKey": "e71b16454abb1aa2b51046dfa3bf461b1dfded42fe1f4ed9",
        "models": [
          {
            "id": "antigravity/gemini-3.7-flash-medium",
            "name": "Gemini 3.7 Flash Medium",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "antigravity/claude-sonnet-4-6",
            "name": "Claude 3.7 Sonnet",
            "contextWindow": 1048576,
            "maxTokens": 32768
          }
        ]
      }
    }
  },
  "mcp": {
    "servers": {
      "search": {
        "url": "https://donsetch.ftp.sh/search",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer 929c0d37a125c23323d1b224ec66c23d" }
      },
      "memory": {
        "url": "https://donsetch.ftp.sh/memory/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer 929c0d37a125c23323d1b224ec66c23d" }
      },
      "crawl": {
        "url": "https://donsetch.ftp.sh/crawl/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer 929c0d37a125c23323d1b224ec66c23d" }
      },
      "context": {
        "url": "https://donsetch.ftp.sh/context/mcp",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer 929c0d37a125c23323d1b224ec66c23d" }
      }
    }
  }
}
EOF
fi

if [ -n "$GATEWAY_TOKEN" ]; then
  openclaw config set gateway.auth.token "$GATEWAY_TOKEN" 2>/dev/null || true
fi

echo "[*] Starting OpenClaw Gateway on port ${PORT:-18789}..."
exec openclaw gateway --port ${PORT:-18789} --allow-unconfigured
