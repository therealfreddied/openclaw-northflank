#!/bin/sh
set -e

dir="/home/nanobot/.nanobot"
mkdir -p "$dir" || echo "[entrypoint] warning: mkdir $dir failed"
config="$dir/config.json"

if [ ! -f "$config" ]; then
    echo "[entrypoint] Initializing $config from template"
    if [ -f "/app/northflank-config.json" ]; then
        cp /app/northflank-config.json "$config"
    elif [ -f "/app/render-config.json" ]; then
        cp /app/render-config.json "$config"
    fi
fi

echo "[entrypoint] Starting nanobot gateway..."
exec /app/.venv/bin/nanobot gateway --foreground --config "$config"
