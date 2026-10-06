#!/bin/sh
set -e

dir="/home/nanobot/.nanobot"
mkdir -p "$dir" || true
config="$dir/config.json"

# Force overwrite with the northflank template so host=0.0.0.0 is always active
echo "[entrypoint] Setting up config at $config..."
cp /app/northflank-config.json "$config"

echo "[entrypoint] Starting nanobot gateway in foreground..."
exec /app/.venv/bin/nanobot gateway --foreground --config "$config"
