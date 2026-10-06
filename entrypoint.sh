#!/bin/sh
set -e
dir="$HOME/.nanobot"

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

if [ "$#" -eq 0 ] || [ "$1" = "status" ]; then
    set -- gateway --config "$config"
else
    set -- "$@" --config "$config"
fi

if [ "$(id -u)" = "0" ]; then
    chown -R nanobot:nanobot "$dir" /home/nanobot 2>/dev/null || true
    if command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid=nanobot --regid=nanobot --init-groups nanobot nanobot "$@"
    elif command -v gosu >/dev/null 2>&1; then
        exec gosu nanobot nanobot "$@"
    else
        exec su -s /bin/sh nanobot -c "nanobot $*"
    fi
else
    exec nanobot "$@"
fi
