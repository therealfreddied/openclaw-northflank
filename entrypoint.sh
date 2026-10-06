#!/bin/sh
# Nanobot entrypoint for Northflank Free Tier (Self-Healing & Crash-Proof)
set -u

dir="/home/nanobot/.nanobot"
mkdir -p "$dir"
config="$dir/config.json"

# Python memory optimization for 512MB / 0.2 vCPU
export MALLOC_ARENA_MAX=2
export PYTHONUNBUFFERED=1
export PYTHONFAULTHANDLER=1

echo "[entrypoint] Generating nanobot configuration at $config ..."
/app/.venv/bin/python - "$config" <<'PYEOF'
import json, os, secrets, sys

config_path = sys.argv[1]

api_base = os.environ.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_API_BASE") or "https://gateway.ai.cloudflare.com/v1/c03418af811230a17c32686972c400fc/openclaw/v1"
api_key = os.environ.get("OPENAI_API_KEY") or os.environ.get("CLOUDFLARE_AI_GATEWAY_KEY") or ""
model_name = os.environ.get("MODEL_NAME") or "cloudflare/google-ai-studio/gemini-3.7-flash"
provider_name = os.environ.get("PROVIDER_NAME") or "cloudflare"

web_token = os.environ.get("NANOBOT_WEB_TOKEN") or secrets.token_hex(24)

# Ensure model has provider prefix if needed
if "/" in model_name and not model_name.startswith(f"{provider_name}/"):
    target_model = f"{provider_name}/{model_name}"
else:
    target_model = model_name if model_name.startswith(f"{provider_name}/") else f"{provider_name}/{model_name}"

cfg = {
    "agents": {
        "defaults": {
            "model": target_model,
            "provider": provider_name,
        }
    },
    "providers": {
        provider_name: {
            "api_key": api_key or "dummy-key",
            "api_base": api_base,
        }
    },
    "gateway": {
        "host": "0.0.0.0",
        "port": 18790
    },
    "channels": {
        "websocket": {
            "enabled": True,
            "host": "0.0.0.0",
            "port": 8765,
            "tokenIssueSecret": web_token,
            "websocketRequiresToken": True,
        }
    }
}

with open(config_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

print(f"[entrypoint] Config active: provider={provider_name}, model={target_model}")
print(f"[entrypoint] Endpoint: {api_base}")
print(f"[entrypoint] WebUI tokenIssueSecret initialized (len={len(web_token)})")
PYEOF

echo "[entrypoint] Starting self-healing supervisor loop for nanobot gateway..."

# Supervisor restart loop: if nanobot ever exits/crashes, restart cleanly after 3s
while true; do
    echo "[supervisor] $(date -u +%FT%TZ) Launching nanobot gateway on 0.0.0.0 (WebUI: 8765, Gateway: 18790)..."
    /app/.venv/bin/nanobot gateway --foreground --config "$config" || true
    code=$?
    echo "[supervisor] $(date -u +%FT%TZ) nanobot gateway exited (code $code) — restarting in 3s..."
    sleep 3
done
