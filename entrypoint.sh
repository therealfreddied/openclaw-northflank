#!/bin/sh
# Nanobot entrypoint for Northflank - hardened against missing files.
set -u

dir="/home/nanobot/.nanobot"
mkdir -p "$dir"

config="$dir/config.json"

# Prefer the Northflank template; fall back to the upstream render template.
if [ -f /app/northflank-config.json ]; then
    cp /app/northflank-config.json "$config"
    echo "[entrypoint] Config installed from northflank-config.json"
elif [ -f /app/render-config.json ]; then
    cp /app/render-config.json "$config"
    echo "[entrypoint] Config installed from render-config.json"
elif [ -f "$config" ]; then
    echo "[entrypoint] Using existing config at $config"
else
    echo "[entrypoint] FATAL: no config template found in /app" >&2
    exit 1
fi

echo "[entrypoint] Starting nanobot gateway..."
exec /app/.venv/bin/nanobot gateway --foreground --config "$config"
