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
/app/.venv/bin/python /app/generate_config.py

echo "[entrypoint] Starting self-healing supervisor loop for nanobot gateway..."

while true; do
    echo "[supervisor] $(date -u +%FT%TZ) Launching nanobot gateway on 0.0.0.0..."
    /app/.venv/bin/nanobot gateway --foreground --config "$config" || true
    code=$?
    echo "[supervisor] $(date -u +%FT%TZ) nanobot gateway exited (code $code) — restarting in 3s..."
    sleep 3
done
