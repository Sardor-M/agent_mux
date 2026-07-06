#!/usr/bin/env bash
# scripts/check_deps.sh — verify required CLIs are installed before `make dev`.

set -euo pipefail

ok=0
fail=0

check() {
    local name="$1"
    local hint="$2"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  ✓ $name  ($(command -v "$name"))"
        ok=$((ok+1))
    else
        echo "  ✗ $name  — install: $hint"
        fail=$((fail+1))
    fi
}

echo "AgentMux dep check:"
check openresty   "brew install openresty/brew/openresty"
check redis-server "brew install redis"

# Only required deps gate startup. Snapshot the failure count here so the
# optional tools below (busted/wrk/stylua) can be missing without aborting
# `make up`/`make dev`.
required_fail=$fail

echo
echo "Optional (for tests / bench / formatting):"
check busted "luarocks install busted"
check wrk    "brew install wrk"
check stylua "brew install stylua"

echo
if [ "$required_fail" -gt 0 ]; then
    echo "Required deps missing — install above and re-run." >&2
    exit 1
fi
echo "All required deps present."
