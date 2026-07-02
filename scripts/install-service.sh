#!/usr/bin/env bash
# scripts/install-service.sh — install/uninstall the agent_mux launchd agent.
#
# Renders conf/launchd/com.agentmux.gateway.plist.template with this repo's
# absolute path + PATH, drops it in ~/Library/LaunchAgents, and loads it so
# agent_mux auto-starts at login and restarts on crash (macOS only).
#
#   scripts/install-service.sh install
#   scripts/install-service.sh uninstall

set -uo pipefail

cd "$(dirname "$0")/.."
PREFIX="$PWD"
LABEL="com.agentmux.gateway"
TEMPLATE="$PREFIX/conf/launchd/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(uname)" != "Darwin" ]; then
    echo "launchd is macOS-only. On Linux, run 'make up' from a systemd unit:" >&2
    echo "  ExecStart=$PREFIX/scripts/agentmux.sh foreground" >&2
    exit 1
fi

case "${1:-install}" in
    install)
        command -v openresty >/dev/null 2>&1 \
            || { echo "openresty not found — brew install openresty/brew/openresty" >&2; exit 1; }
        [ -f "$TEMPLATE" ] || { echo "template missing: $TEMPLATE" >&2; exit 1; }
        mkdir -p "$HOME/Library/LaunchAgents" "$PREFIX/logs" "$PREFIX/run"

        sed -e "s|__REPO__|$PREFIX|g" -e "s|__PATH__|$PATH|g" "$TEMPLATE" > "$PLIST_DST"

        launchctl unload "$PLIST_DST" 2>/dev/null || true
        if launchctl load -w "$PLIST_DST"; then
            echo "installed + loaded: $PLIST_DST"
            echo "agent_mux now auto-starts at login and restarts on crash."
            echo "  status:  make status"
            echo "  stop:    make service-uninstall   (or: launchctl unload -w $PLIST_DST)"
        else
            echo "failed to load $PLIST_DST — check logs/launchd.err.log" >&2
            exit 1
        fi
        ;;
    uninstall)
        launchctl unload -w "$PLIST_DST" 2>/dev/null || true
        rm -f "$PLIST_DST"
        echo "removed launchd agent: $PLIST_DST"
        echo "(the current background process, if any, keeps running until 'make down')"
        ;;
    *)
        echo "usage: $(basename "$0") {install|uninstall}" >&2
        exit 2
        ;;
esac
