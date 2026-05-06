#!/usr/bin/env bash
# scripts/bench.sh — micro-benchmark with wrk against `make demo`.
#
# Three workloads, each run for $DURATION seconds with $CONNS connections:
#
#   1. /healthz             — pure nginx + Lua phase overhead. Floor.
#   2. /metrics             — nginx + module-locals + cjson encode.
#   3. /v1/agents (default) — full agent loop against the mock upstream
#                             with a single text turn (no tools).
#
# Output:
#   - bench/run_YYYYMMDD_HHMMSS.txt   (raw wrk output for the run)
#   - bench/baseline.txt              (last-good numbers, manually pinned)
#
# Compare a new run vs the baseline by hand. CI integration is a stretch.

set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${DURATION:-30s}"
CONNS="${CONNS:-10}"
THREADS="${THREADS:-2}"
HOST="${HOST:-localhost:8080}"
API_KEY="${AGENT_MUX_API_KEY:-}"

if ! command -v wrk >/dev/null 2>&1; then
    echo "wrk not installed — brew install wrk" >&2
    exit 1
fi

mkdir -p bench
TS="$(date +%Y%m%d_%H%M%S)"
OUT="bench/run_${TS}.txt"

# wrk POST script for /v1/agents.
POST_LUA="$(mktemp /tmp/agent_mux_bench_post.XXXXXX.lua)"
trap 'rm -f "$POST_LUA"' EXIT

cat > "$POST_LUA" <<EOF
wrk.method  = "POST"
wrk.headers["Content-Type"] = "application/json"
${API_KEY:+wrk.headers["X-API-Key"] = "${API_KEY}"}
wrk.body    = '{"model":"mock-claude","messages":[{"role":"user","content":"hi"}]}'
EOF

{
    echo "================================================================"
    echo "AgentMux bench — $TS"
    echo "host=$HOST conns=$CONNS threads=$THREADS duration=$DURATION"
    echo "================================================================"
    echo

    echo "--- 1. /healthz (floor: pure nginx + Lua) ---"
    wrk -t "$THREADS" -c "$CONNS" -d "$DURATION" --latency "http://$HOST/healthz"
    echo

    echo "--- 2. /metrics (nginx + module-locals + JSON) ---"
    wrk -t "$THREADS" -c "$CONNS" -d "$DURATION" --latency "http://$HOST/metrics"
    echo

    echo "--- 3. /v1/agents (full agent loop, mock upstream, one turn) ---"
    wrk -t "$THREADS" -c "$CONNS" -d "$DURATION" --latency \
        -s "$POST_LUA" "http://$HOST/v1/agents"
    echo
} | tee "$OUT"

echo
echo "Run output:  $OUT"
echo "Baseline:    bench/baseline.txt  (manually pin a clean run as the ref)"
echo
echo "To pin this run as the new baseline:  cp $OUT bench/baseline.txt"
