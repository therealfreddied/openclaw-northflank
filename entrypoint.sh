#!/bin/sh
set -e

dir="/home/nanobot/.nanobot"
mkdir -p "$dir" || true
config="$dir/config.json"

if [ ! -f "$config" ]; then
    echo "[entrypoint] Copying northflank-config.json to $config"
    cp /app/northflank-config.json "$config"
fi

echo "[entrypoint] Starting nanobot gateway..."
exec /app/.venv/bin/python -m nanobot.cli.entry gateway --foreground --config "$config"
