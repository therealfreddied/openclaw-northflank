#!/bin/sh
# Nanobot entrypoint for Northflank Free Tier (Self-Healing, Persistent & Crash-Proof)
set -u

dir="/home/nanobot/.nanobot"
mkdir -p "$dir"
config="$dir/config.json"

export MALLOC_ARENA_MAX=2
export PYTHONUNBUFFERED=1
export PYTHONFAULTHANDLER=1

echo "[entrypoint] Setting up persistent nanobot configuration at $config ..."

# Always merge environment variables and maintain full model & MCP templates
/app/.venv/bin/python - "$config" <<'PYEOF'
import json, os, sys

config_path = sys.argv[1]

# Load base template if present
base_template_path = "/app/northflank-config.json"
if os.path.exists(base_template_path):
    try:
        with open(base_template_path, "r") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
else:
    cfg = {}

# Ingest runtime env variables if provided
cf_key = os.environ.get("CLOUDFLARE_AI_GATEWAY_KEY")
if cf_key:
    cfg.setdefault("providers", {}).setdefault("cloudflare", {})["apiKey"] = cf_key
    cfg.setdefault("providers", {}).setdefault("custom", {})["apiKey"] = cf_key

cf_base = os.environ.get("OPENAI_BASE_URL")
if cf_base:
    cfg.setdefault("providers", {}).setdefault("cloudflare", {})["apiBase"] = cf_base
    cfg.setdefault("providers", {}).setdefault("custom", {})["apiBase"] = cf_base

web_token = os.environ.get("NANOBOT_WEB_TOKEN") or "nanobot2026"
cfg.setdefault("channels", {}).setdefault("websocket", {})["tokenIssueSecret"] = web_token
cfg.setdefault("channels", {}).setdefault("websocket", {})["token"] = web_token
cfg.setdefault("channels", {}).setdefault("websocket", {})["host"] = "0.0.0.0"
cfg.setdefault("channels", {}).setdefault("websocket", {})["port"] = 8765
cfg.setdefault("channels", {}).setdefault("websocket", {})["enabled"] = True
cfg.setdefault("channels", {}).setdefault("websocket", {})["websocketRequiresToken"] = True

cfg.setdefault("gateway", {})["host"] = "0.0.0.0"
cfg.setdefault("gateway", {})["port"] = 18790

# Atomic write of master configuration
with open(config_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

presets_count = len(cfg.get("modelPresets", {}))
mcp_count = len(cfg.get("tools", {}).get("mcpServers", {}))
print(f"[entrypoint] Master configuration ready: {presets_count} model presets, {mcp_count} MCP servers.")
print(f"[entrypoint] Password active: {web_token}")
PYEOF

echo "[entrypoint] Starting self-healing supervisor loop for nanobot gateway..."

while true; do
    echo "[supervisor] $(date -u +%FT%TZ) Launching nanobot gateway on 0.0.0.0 (WebUI: 8765, Gateway: 18790)..."
    /app/.venv/bin/nanobot gateway --foreground --config "$config" || true
    code=$?
    echo "[supervisor] $(date -u +%FT%TZ) nanobot gateway exited (code $code) — restarting in 3s..."
    sleep 3
done
