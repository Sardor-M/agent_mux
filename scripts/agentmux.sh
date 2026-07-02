#!/usr/bin/env bash
# scripts/agentmux.sh — run agent_mux as a background service.
#
# Daemonizes redis + OpenResty so the MCP gateway is always up in the
# background (no terminal to babysit, unlike `make dev`/`make demo`). Point
# Claude Code / Codex at http://localhost:8080/mcp and leave it running.
#
#   scripts/agentmux.sh start      # daemonize redis + OpenResty, wait for /healthz
#   scripts/agentmux.sh stop       # graceful stop (drains in-flight sessions)
#   scripts/agentmux.sh restart
#   scripts/agentmux.sh status     # up/down + supervised MCP servers
#   scripts/agentmux.sh logs       # tail the worker log
#   scripts/agentmux.sh foreground # run in foreground (used by the launchd agent)
#
# Config: sources ./.env if present (see .env.example), then applies defaults.
# Works with no .env for local use — auth runs allow-all in dev without keys.

set -uo pipefail

cd "$(dirname "$0")/.."
PREFIX="$PWD"

# Load optional local config, exporting everything it sets so it crosses into
# the OpenResty master (nginx.conf declares which env vars reach the worker).
if [ -f "$PREFIX/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PREFIX/.env"
    set +a
fi

OPENRESTY="${OPENRESTY:-openresty}"
HOST="${AGENT_MUX_HOST:-http://localhost:8080}"
REDIS_PORT="${REDIS_PORT:-6390}"
# Supervise the demo MCP server out of the box; override in .env to point at
# your own manifest (or set to an empty file to run the gateway tool-less).
export AGENT_MUX_MCP_FILE="${AGENT_MUX_MCP_FILE:-examples/tools/mcp_servers.json}"
export REDIS_PORT

NGINX_PID="$PREFIX/run/nginx.pid"
REDIS_PID="$PREFIX/run/redis.pid"

log()  { printf '[agentmux] %s\n' "$*"; }
die()  { printf '[agentmux] error: %s\n' "$*" >&2; exit 1; }

pid_alive()     { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
nginx_running() { pid_alive "$NGINX_PID"; }
redis_running() { pid_alive "$REDIS_PID"; }

redis_responds() { command -v redis-cli >/dev/null 2>&1 && redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1; }

start_redis() {
    if redis_running; then
        log "redis already running (pid $(cat "$REDIS_PID"), :$REDIS_PORT)"
        return
    fi
    # Something else may already hold the port (e.g. a prior `make demo`). Reuse
    # it rather than fighting over the bind — the app fails open on redis anyway.
    if redis_responds; then
        log "redis already listening on :$REDIS_PORT (not started by us) — reusing"
        return
    fi
    command -v redis-server >/dev/null 2>&1 || die "redis-server not found — brew install redis"
    log "starting redis on :$REDIS_PORT"
    redis-server --port "$REDIS_PORT" --daemonize yes \
        --pidfile "$REDIS_PID" --dir "$PREFIX/run" \
        --logfile "$PREFIX/logs/redis.log" --save "" \
        || die "redis failed to start — see logs/redis.log"
    # `--daemonize yes` returns 0 before the child binds, so a bind failure is
    # silent. Confirm it actually came up (skip if redis-cli isn't installed).
    if command -v redis-cli >/dev/null 2>&1; then
        local i
        for i in $(seq 1 15); do
            if redis_responds; then return; fi
            sleep 0.2
        done
        die "redis started but not responding on :$REDIS_PORT — see logs/redis.log"
    fi
}

wait_healthy() {
    local i
    for i in $(seq 1 20); do
        if curl -fsS --max-time 1 "$HOST/healthz" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    return 1
}

cmd_start() {
    mkdir -p "$PREFIX/logs" "$PREFIX/run"
    if nginx_running; then
        log "already running (nginx pid $(cat "$NGINX_PID"))"
        cmd_status
        return
    fi
    command -v "$OPENRESTY" >/dev/null 2>&1 \
        || die "$OPENRESTY not found — brew install openresty/brew/openresty"
    start_redis
    log "starting OpenResty (daemon) on :8080"
    # nginx daemonizes by default; the master pidfile is run/nginx.pid (nginx.conf).
    "$OPENRESTY" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" \
        || die "OpenResty failed to start — see logs/error.log"
    if wait_healthy; then
        log "up ✓   health: $HOST/healthz   gateway: $HOST/mcp   fleet: make status"
    else
        log "started, but /healthz didn't respond in time — check logs/error.log"
    fi
}

cmd_stop() {
    if nginx_running; then
        log "stopping OpenResty (graceful drain)…"
        "$OPENRESTY" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" -s quit 2>/dev/null \
            || "$OPENRESTY" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" -s stop 2>/dev/null \
            || true
    else
        log "OpenResty not running"
    fi
    if redis_running; then
        log "stopping redis…"
        kill "$(cat "$REDIS_PID")" 2>/dev/null || true
        rm -f "$REDIS_PID"
    fi
}

cmd_status() {
    if nginx_running; then log "OpenResty: up (pid $(cat "$NGINX_PID"))"
    else                    log "OpenResty: down"; fi
    if redis_running; then  log "redis: up (pid $(cat "$REDIS_PID"), :$REDIS_PORT)"
    else                    log "redis: down"; fi
    # Show the supervised MCP fleet if the gateway is answering.
    if curl -fsS --max-time 2 "$HOST/v1/mcp/servers?format=text" 2>/dev/null; then
        :
    elif curl -fsS --max-time 2 "$HOST/healthz" >/dev/null 2>&1; then
        log "gateway healthy (no MCP servers configured)"
    else
        log "gateway unreachable at $HOST"
    fi
}

# Foreground mode for launchd: start redis in the background, then exec
# OpenResty in the foreground so launchd supervises the master directly
# (its KeepAlive restarts the whole service if the master dies).
cmd_foreground() {
    mkdir -p "$PREFIX/logs" "$PREFIX/run"
    command -v "$OPENRESTY" >/dev/null 2>&1 || die "$OPENRESTY not found"
    start_redis
    log "running OpenResty in foreground (launchd-supervised)"
    exec "$OPENRESTY" -p "$PREFIX/" -c "$PREFIX/conf/nginx.conf" -g 'daemon off;'
}

case "${1:-}" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_stop; sleep 1; cmd_start ;;
    status)     cmd_status ;;
    foreground) cmd_foreground ;;
    logs)       exec tail -f "$PREFIX/logs/error.log" ;;
    *)          echo "usage: $(basename "$0") {start|stop|restart|status|logs|foreground}" >&2; exit 2 ;;
esac
