#!/usr/bin/env bash
set -euo pipefail
# Lumen Stop hook — nudges Claude to capture knowledge after each response turn.
# Fires on the Stop event (end of Claude's response).

TOOL_NAME="${1:-}"

if [[ "$TOOL_NAME" == "Stop" ]]; then
  STATS=$(lumen status --json 2>/dev/null) || true
  CONCEPTS=$(echo "$STATS" | grep -o '"concepts":[0-9]*' | cut -d: -f2 || echo "0")
  CONCEPTS="${CONCEPTS:-0}"

  if [[ "$CONCEPTS" -gt 0 ]]; then
    echo "Lumen brain has $CONCEPTS concepts. If this response contained new knowledge, original thinking, or notable entity mentions — call the capture MCP tool now to grow the brain before the session ends."
  else
    echo "Lumen brain is empty. If the user shared anything worth remembering, call capture to start growing the brain."
  fi
fi
