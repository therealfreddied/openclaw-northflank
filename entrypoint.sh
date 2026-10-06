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

echo "[entrypoint] Launching nanobot gateway with config $config"

if [ "$(id -u)" = "0" ]; then
    chown -R nanobot:nanobot "$dir" /home/nanobot /app 2>/dev/null || true
    if command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid=nanobot --regid=nanobot --init-groups nanobot /app/.venv/bin/nanobot gateway --config "$config"
    elif command -v gosu >/dev/null 2>&1; then
        exec gosu nanobot /app/.venv/bin/nanobot gateway --config "$config"
    else
        exec su -s /bin/sh nanobot -c "/app/.venv/bin/nanobot gateway --config $config"
    fi
else
    exec /app/.venv/bin/nanobot gateway --config "$config"
fi
