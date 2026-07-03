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

cd "$(dirname "$0")/.." || exit 1
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

        # Use bash substitution instead of sed to avoid delimiter collision if
        # $PREFIX or $PATH contain characters like |, &, or <.
        content=$(cat "$TEMPLATE")
        content="${content//__REPO__/$PREFIX}"
        content="${content//__PATH__/$PATH}"
        printf '%s\n' "$content" > "$PLIST_DST"

        # launchctl load -w is deprecated since macOS 10.10; use bootstrap/bootout.
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"; then
            echo "installed + loaded: $PLIST_DST"
            echo "agent_mux now auto-starts at login and restarts on crash."
            echo "  status:  make status"
            echo "  stop:    make service-uninstall"
        else
            echo "failed to load $PLIST_DST — check logs/launchd.err.log" >&2
            exit 1
        fi
        ;;
    uninstall)
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$PLIST_DST"
        echo "removed launchd agent: $PLIST_DST"
        echo "(the current background process, if any, keeps running until 'make down')"
        ;;
    *)
        echo "usage: $(basename "$0") {install|uninstall}" >&2
        exit 2
        ;;
esac
