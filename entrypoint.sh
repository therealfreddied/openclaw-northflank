#!/bin/sh
set -e

dir="/home/nanobot/.nanobot"
mkdir -p "$dir" || true
config="$dir/config.json"

echo "[entrypoint] Writing active nanobot config to $config"
cp /app/northflank-config.json "$config"

echo "[entrypoint] Starting nanobot gateway on 0.0.0.0 (WebUI port 8765, Gateway port 18790)..."
exec /app/.venv/bin/nanobot gateway --foreground --config "$config" --port 18790
