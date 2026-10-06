#!/usr/bin/env bash
set -e

echo "[*] Initializing 9router + OpenClaw unified free stack..."

mkdir -p /root/.9router
mkdir -p /root/.openclaw/workspace

# 1. Configure 9router Gemini Key Pool if GEMINI_KEYS or GEMINI_API_KEY provided
if [ -n "$GEMINI_KEYS" ] || [ -n "$GEMINI_API_KEY" ]; then
  KEYS_RAW="${GEMINI_KEYS:-$GEMINI_API_KEY}"
  echo "[*] Configuring 9router with rotating Gemini API keys..."
  
  # Format keys array as JSON
  python3 -c "
import json, os
raw = os.environ.get('GEMINI_KEYS') or os.environ.get('GEMINI_API_KEY') or ''
keys = [k.strip() for k in raw.replace(';', ',').split(',') if k.strip()]
config = {
    'port': 20129,
    'host': '127.0.0.1',
    'providers': {
        'gemini': {
            'apiKeys': keys,
            'strategy': 'round-robin',
            'retryOn429': True
        }
    }
}
os.makedirs('/root/.9router', exist_ok=True)
with open('/root/.9router/config.json', 'w') as f:
    json.dump(config, f, indent=2)
print(f'Successfully initialized 9router with {len(keys)} Gemini key(s)!')
"
  echo "[*] Launching 9router on 127.0.0.1:20129..."
  NODE_OPTIONS="--max-old-space-size=96" 9router start --port 20129 &
  sleep 2
else
  echo "[i] No GEMINI_KEYS passed. 9router idle; fallback to direct OmniRoute gateway."
fi

# 2. Configure OpenClaw Gateway
if [ ! -f /root/.openclaw/openclaw.json ]; then
cat << 'EOF' > /root/.openclaw/openclaw.json
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "***"
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
        "apiKey": "***",
        "models": [
          {
            "id": "gemini-2.5-flash",
            "name": "Gemini 2.5 Flash (9router Rotator)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "gemini-2.5-pro",
            "name": "Gemini 2.5 Pro (9router Rotator)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          },
          {
            "id": "gemini-2.0-flash",
            "name": "Gemini 2.0 Flash (9router Rotator)",
            "contextWindow": 1048576,
            "maxTokens": 32768
          }
        ]
      },
      "omniroute": {
        "baseUrl": "https://api.nullroute.lol/v1",
        "api": "openai-completions",
        "apiKey": "***",
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

# 3. Launch OpenClaw Gateway (capped to 256MB RAM)
echo "[*] Launching OpenClaw Gateway on port ${PORT:-18789}..."
export NODE_OPTIONS="--max-old-space-size=256"
exec openclaw gateway --port ${PORT:-18789} --allow-unconfigured
