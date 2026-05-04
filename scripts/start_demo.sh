#!/usr/bin/env bash
# scripts/start_demo.sh — boot redis + OpenResty for a local demo.
#
# v0.1 scaffolding: redis is started on a random port and OpenResty is
# foregrounded on :8080. The agent loop is not implemented yet; this just
# verifies the stack boots cleanly. /healthz, /metrics, and /mock/v1/messages
# all respond.

set -euo pipefail

cd "$(dirname "$0")/.."
PREFIX="$PWD"

mkdir -p logs run

REDIS_PORT="${REDIS_PORT:-6390}"

cleanup() {
    echo
    echo "[demo] stopping…"
    if [ -f run/redis.pid ]; then
        kill "$(cat run/redis.pid)" 2>/dev/null || true
        rm -f run/redis.pid
    fi
    "${OPENRESTY:-openresty}" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" -s stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[demo] starting redis on :$REDIS_PORT"
redis-server --port "$REDIS_PORT" --daemonize yes --pidfile "$PREFIX/run/redis.pid" \
             --logfile "$PREFIX/logs/redis.log" --save ""

echo "[demo] starting OpenResty on :8080 (Ctrl+C to stop)"
echo "[demo] try:"
echo "         curl localhost:8080/healthz"
echo "         curl localhost:8080/metrics"
echo "         curl -N localhost:8080/mock/v1/messages   (live SSE stream)"
echo
exec "${OPENRESTY:-openresty}" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" -g 'daemon off;'
