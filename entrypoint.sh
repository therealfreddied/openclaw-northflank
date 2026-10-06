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

echo "[entrypoint] Initializing nanobot configuration at $config ..."
/app/.venv/bin/python - "$config" <<'PYEOF'
import json, os, secrets, sys

config_path = sys.argv[1]

api_base = os.environ.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_API_BASE") or "https://api.openai.com/v1"
api_key = ***"OPENAI_API_KEY") or ""
model_name = os.environ.get("MODEL_NAME") or "gpt-4o"
provider_name = os.environ.get("PROVIDER_NAME") or "custom"

# WebUI Password: use env var if provided, otherwise default to a clean fixed password
web_token = os.environ.get("NANOBOT_WEB_TOKEN") or "nanobot2026"

# Format model name with provider prefix if needed
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
            "token": web_token,
            "websocketRequiresToken": True,
        }
    }
}

with open(config_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

print("================================================================")
print("  🔐 NANOBOT WEBUI LOGIN PASSWORD:")
print(f"     {web_token}")
print("================================================================")
print(f"[entrypoint] Model: {target_model} via {api_base}")
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
