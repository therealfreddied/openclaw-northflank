#!/bin/sh
set -e

dir="/home/nanobot/.nanobot"
mkdir -p "$dir" || true
config="$dir/config.json"

echo "[entrypoint] Setting up nanobot configuration at $config..."
cp /app/northflank-config.json "$config"

echo "[entrypoint] Starting nanobot gateway..."
# Execute nanobot gateway directly using the installed uv venv entrypoint
exec /app/.venv/bin/python -c '
import sys
from nanobot.config.loader import load_config
from nanobot.cli.gateway_runtime import _run_gateway

cfg = load_config("/home/nanobot/.nanobot/config.json")
print("[entrypoint] Loaded configuration successfully:", cfg)
_run_gateway(cfg, port=18790, health_server_enabled=True)
'
