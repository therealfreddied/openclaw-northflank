#!/bin/sh
# Nanobot entrypoint for Northflank.
# Generates a valid, self-authenticating config at runtime so the gateway
# always passes its wildcard-host validation (host 0.0.0.0 requires a token).
set -u

dir="/home/nanobot/.nanobot"
mkdir -p "$dir"
config="$dir/config.json"

echo "[entrypoint] Generating nanobot config at $config ..."
/app/.venv/bin/python - "$config" <<'PYEOF'
import json, os, secrets, sys

config_path = sys.argv[1]

cf_key = os.environ.get("CLOUDFLARE_AI_GATEWAY_KEY", "")
web_token = os.environ.get("NANOBOT_WEB_TOKEN") or secrets.token_hex(24)

cfg = {
    "agents": {
        "defaults": {
            "model": "cloudflare/google-ai-studio/gemini-3.7-flash",
            "provider": "cloudflare",
        }
    },
    "providers": {
        "cloudflare": {
            "api_key": cf_key or "not-configured",
            "api_base": "https://gateway.ai.cloudflare.com/v1/c03418af811230a17c32686972c400fc/openclaw/v1",
        }
    },
    "gateway": {"host": "0.0.0.0", "port": 18790},
    "channels": {
        "websocket": {
            "enabled": True,
            "host": "0.0.0.0",
            "port": 8765,
            # Non-empty token is REQUIRED: nanobot refuses host 0.0.0.0 without auth.
            "tokenIssueSecret": web_token,
            "websocketRequiresToken": True,
        }
    },
}

with open(config_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

print("[entrypoint] config written; tokenIssueSecret len =", len(web_token))
print("[entrypoint] cloudflare key configured:", bool(cf_key))
PYEOF

echo "[entrypoint] Starting nanobot gateway ..."
exec /app/.venv/bin/nanobot gateway --foreground --config "$config"