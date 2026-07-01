#!/usr/bin/env bash
# agent-mux-status — glance at the supervised MCP server fleet.
#
# Reads GET /v1/mcp/servers?format=text (rendered server-side, so no jq
# needed) and prints the table. With --watch it redraws on an interval so
# you can leave it open next to your editor.
#
# Usage:
#   scripts/agent-mux-status.sh              # one-shot table
#   scripts/agent-mux-status.sh --watch      # live view (Ctrl+C to exit)
#   scripts/agent-mux-status.sh --watch 5    # live view, 5s interval
#
# Env:
#   AGENT_MUX_HOST      base URL      (default http://localhost:8080)
#   AGENT_MUX_API_KEY   sent as X-API-Key if set
set -uo pipefail

HOST="${AGENT_MUX_HOST:-http://localhost:8080}"
URL="$HOST/v1/mcp/servers?format=text"

AUTH=()
if [[ -n "${AGENT_MUX_API_KEY:-}" ]]; then
  AUTH=(-H "X-API-Key: ${AGENT_MUX_API_KEY}")
fi

fetch() {
  curl -fsS --max-time 5 "${AUTH[@]}" "$URL" 2>/dev/null \
    || printf 'agent_mux unreachable at %s\n(is it running? try: make demo)\n' "$HOST"
}

if [[ "${1:-}" == "--watch" ]]; then
  interval="${2:-2}"
  printf '\e[?25l'                       # hide cursor
  trap 'printf "\e[?25h\n"' EXIT INT TERM # restore cursor on exit
  while true; do
    out="$(fetch)"
    printf '\e[H\e[2J'                    # cursor home + clear screen
    printf 'agent_mux MCP fleet — %s   (every %ss, Ctrl+C to exit)\n\n' \
      "$(date '+%H:%M:%S')" "$interval"
    printf '%s\n' "$out"
    sleep "$interval"
  done
else
  fetch
fi
