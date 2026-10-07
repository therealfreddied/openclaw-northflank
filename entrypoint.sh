#!/bin/sh
# Nanobot entrypoint for Railway & Northflank (Self-Healing, Persistent & Crash-Proof)
set -u

dir="/home/nanobot/.nanobot"
mkdir -p "$dir"
config="$dir/config.json"

export MALLOC_ARENA_MAX=2
export PYTHONUNBUFFERED=1
export PYTHONFAULTHANDLER=1

echo "[entrypoint] Initializing Nanobot configuration at $config ..."

/app/.venv/bin/python - "$config" <<'PYEOF'
import json, os, sys, base64

config_path = sys.argv[1]

# Load base template if present
base_template = "/app/railway-config.json" if os.path.exists("/app/railway-config.json") else "/app/northflank-config.json"
if os.path.exists(base_template):
    try:
        with open(base_template, "r") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
else:
    cfg = {}

# Ensure standard structures
cfg.setdefault("agents", {}).setdefault("defaults", {})
cfg.setdefault("providers", {})
cfg.setdefault("tools", {}).setdefault("mcpServers", {})
cfg.setdefault("channels", {}).setdefault("websocket", {})
cfg.setdefault("gateway", {})

# MCP Auth & Headers
raw_mcp_auth = base64.b64decode(b"QmVhcmVyIHNrLWM0ZmYyZTEwNzVjMjBlNjNmYTU3MmJiMmY1ZDlkNmNjMzA5MWQ5NjY2YWM1YWI0Zg==").decode()
nullroute_auth = os.environ.get("NULLROUTE_MCP_AUTH") or raw_mcp_auth
ua_header = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 1. 4x NullRoute MCP Servers (Search, Memory, Crawl, Context)
cfg["tools"]["mcpServers"] = {
    "nullroute_search": {
        "type": "streamableHttp",
        "url": "https://api.nullroute.lol/search/mcp",
        "headers": {
            "Authorization": ***,
            "User-Agent": ua_header
        },
        "toolTimeout": 60,
        "enabledTools": ["*"]
    },
    "nullroute_memory": {
        "type": "streamableHttp",
        "url": "https://api.nullroute.lol/memory/mcp",
        "headers": {
            "Authorization": ***,
            "User-Agent": ua_header
        },
        "toolTimeout": 30,
        "enabledTools": ["*"]
    },
    "nullroute_crawl": {
        "type": "streamableHttp",
        "url": "https://api.nullroute.lol/crawl/mcp",
        "headers": {
            "Authorization": ***,
            "User-Agent": ua_header
        },
        "toolTimeout": 120,
        "enabledTools": ["*"]
    },
    "nullroute_context": {
        "type": "streamableHttp",
        "url": "https://api.nullroute.lol/context/mcp",
        "headers": {
            "Authorization": ***,
            "User-Agent": ua_header
        },
        "toolTimeout": 45,
        "enabledTools": ["*"]
    }
}

# 2. WebUI Authentication - Default Password: Fuckedbypyr0!
web_token = os.environ.get("NANOBOT_WEB_TOKEN") or "Fuckedbypyr0!"
port_num = int(os.environ.get("PORT") or 8765)

cfg["channels"]["websocket"] = {
    "enabled": True,
    "host": "0.0.0.0",
    "port": port_num,
    "tokenIssueSecret": web_token,
    "token": web_token,
    "websocketRequiresToken": True
}

cfg["gateway"]["host"] = "0.0.0.0"
cfg["gateway"]["port"] = 18790
cfg["agents"]["defaults"]["workspace"] = "~/.nanobot/workspace"

# Write out configuration
with open(config_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

print(f"[entrypoint] Configuration generated with 4 NullRoute MCP servers.")
print(f"[entrypoint] WebUI Port: {port_num}")
print(f"[entrypoint] Password active: {web_token}")
PYEOF

echo "[entrypoint] Starting self-healing supervisor loop for nanobot gateway..."

while true; do
    echo "[supervisor] $(date -u +%FT%TZ) Launching nanobot gateway on 0.0.0.0..."
    /app/.venv/bin/nanobot gateway --foreground --config "$config" || true
    code=$?
    echo "[supervisor] $(date -u +%FT%TZ) nanobot gateway exited (code $code) — restarting in 3s..."
    sleep 3
done
