# AgentMux — Testing Guide

A copy-paste walkthrough you can run end-to-end on a local machine to validate
every feature works against a real OpenResty + Redis + Lua loop. No real
Anthropic key is needed — every scenario uses the in-tree mock upstream
(`examples/mock_anthropic.lua`).

If a step doesn't behave as described, that's a real bug. Each scenario notes
what part of the system it's actually exercising.

## Setup

One-time dependencies (macOS):

```bash
brew install openresty/brew/openresty redis luarocks
luarocks install busted
```

Verify:

```bash
make check-deps
```

You should see ✓ for `openresty`, `redis-server`, and `busted`.

## Boot

In one terminal:

```bash
export AGENT_MUX_API_KEYS=test-key
make demo
```

`make demo` starts redis on `:6390` and OpenResty in the foreground on `:8080`.
Leave it running. Open a second terminal for the rest of the scenarios.

> All curls below assume the `AGENT_MUX_API_KEYS=test-key` from the boot
> terminal. If you want auth disabled, unset it before `make demo` and
> drop the `X-API-Key` header — auth runs in allow-all dev mode without keys.

## Scenario 1 — health and metrics

**What it tests:** worker init, env propagation, redis reachability, metrics
registry populated and rendered.

```bash
curl -fsS localhost:8080/healthz
# → ok

curl -fsS localhost:8080/metrics | grep -E '^agent_mux_(build_info|redis_up)'
# → agent_mux_build_info{version="0.3.0-dev"} 1
# → agent_mux_redis_up 1
```

If `redis_up` is `0`, the Lua code reached `/metrics` but couldn't ping redis —
check that `make demo`'s redis subprocess is running (`run/redis.pid`).

## Scenario 2 — auth gate

**What it tests:** `auth_request` policy reads `AGENT_MUX_API_KEYS` from the
worker env and rejects mismatched / missing keys with 401.

```bash
# missing header → 401
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
     -X POST -H 'Content-Type: application/json' \
     -d '{"model":"mock-claude","messages":[{"role":"user","content":"hi"}]}' \
     localhost:8080/v1/agents
# → HTTP 401

# wrong key → 401
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
     -X POST -H 'Content-Type: application/json' -H 'X-API-Key: nope' \
     -d '{"model":"mock-claude","messages":[{"role":"user","content":"hi"}]}' \
     localhost:8080/v1/agents
# → HTTP 401

# correct key → 200 (and SSE body, see scenario 3)
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
     -X POST -H 'Content-Type: application/json' -H 'X-API-Key: test-key' \
     -d '{"model":"mock-claude","messages":[{"role":"user","content":"hi"}]}' \
     localhost:8080/v1/agents
# → HTTP 200
```

## Scenario 3 — basic agent loop, text only

**What it tests:** the full request → access phase → session create → agent
loop → mock upstream → SSE encode → log phase pipeline.

```bash
curl -N -X POST localhost:8080/v1/agents \
     -H 'X-API-Key: test-key' \
     -H 'Content-Type: application/json' \
     --data @examples/agent_request.json
```

Expected SSE event sequence (each line is `event: <name>\ndata: <json>\n\n`):

```
event: session_start         { "session_id": "sess_…", "model": "mock-claude" }
event: turn_start             { "turn": 1 }
event: model_chunk            { "turn": 1, "text": "Hello! …" }   (one or more)
event: turn_complete          { "turn": 1, "stop_reason": "end_turn", … }
event: done                   { "stop_reason": "end_turn", "turns": 1 }
event: end                    {}
```

Stop reasons other than `end_turn` here mean the loop bailed early — check
the worker `logs/error.log`.

## Scenario 4 — tool dispatch (calculator + HTTP search)

**What it tests:** inline tool registry, HTTP tool registry, concurrent tool
fan-out within a single assistant turn, mock returning multi-tool turn,
and the second loop iteration that processes `tool_results`.

The mock emits a tool-use turn when `metadata.scenario == "tool_use"`:

```bash
curl -N -X POST localhost:8080/v1/agents \
     -H 'X-API-Key: test-key' \
     -H 'Content-Type: application/json' \
     -d '{
       "model": "mock-claude",
       "messages": [
         { "role": "user", "content": "what is 2+2 and search for cosockets?" }
       ],
       "metadata": { "scenario": "tool_use" }
     }'
```

Look for these events in order:

```
event: turn_start                   { "turn": 1 }
event: tool_dispatch_start          { "count": 2 }
event: tool_call                    { "name": "calculator", … }
event: tool_call                    { "name": "search", … }
event: tool_result                  { "tool_use_id": "…", "content": "4" }
event: tool_result                  { "tool_use_id": "…", "content": "…" }
event: tool_dispatch_complete       { "count": 2, "errors": 0 }
event: turn_start                   { "turn": 2 }
event: model_chunk                  { "turn": 2, "text": "…" }
event: done                         { "stop_reason": "end_turn", "turns": 2 }
```

If `errors > 0` on `tool_dispatch_complete`, one of the tool runners failed
— commonly the HTTP `search` tool can't reach `localhost:8080/mock/tools/search`
because nginx isn't routing internal requests cleanly. Check `logs/error.log`.

## Scenario 5 — MCP server supervision

**What it tests:** the MCP supervisor — subprocess spawn from a manifest,
JSON-RPC handshake, and **respawn with exponential backoff** when the server
dies. Recovery is driven two ways: a background sweep (`ngx.timer.every`,
every 5s) respawns dead servers proactively, and the tool-call path respawns
lazily on demand — whichever happens first. Backoff escalates per attempt and
tops out at ~25.6s.

Stop the demo and re-boot with the MCP manifest enabled:

```bash
# in the demo shell: Ctrl+C, then:
AGENT_MUX_API_KEYS=test-key \
AGENT_MUX_MCP_FILE=examples/tools/mcp_servers.json \
make demo
```

Verify the supervised subprocess is up:

```bash
ps -ef | grep -v grep | grep mcp_demo/server.py
# → one python3 process, child of the openresty worker
```

In the demo shell's stdout (or `logs/error.log`), you should see lines like:

```
[lua] mcp.lua: spawned MCP server "demo" (pid=NNNN)
[lua] mcp.lua: registered 2 tools from "demo": demo:get_time, demo:echo
```

Now kill the subprocess and wait one supervisor interval (5s) for the
background sweep to respawn it:

```bash
pkill -f mcp_demo/server.py
sleep 6
ps -ef | grep -v grep | grep mcp_demo/server.py
# → still one process, NEW pid — respawned by the supervisor sweep
```

You should see `mcp_server_died: respawning demo` then
`mcp_server_respawned: demo` in the log. Tail `logs/error.log` while you kill
it several times in a row; the respawn delay grows per attempt (exponential
backoff, ~25.6s ceiling), so later kills take longer than 5s to recover.

```bash
tail -f logs/error.log | grep -i 'mcp'
# (in another shell) pkill -f mcp_demo/server.py    # repeat
```

You can also trigger recovery immediately — without waiting for the sweep —
by invoking a tool from the dead server; the tool-call path respawns it on
demand (subject to the same backoff).

## Scenario 6 — cancel an in-flight session

**What it tests:** the `DELETE /v1/sessions/:id` cancellation path; the loop
checks the cancellation flag between turns and emits a `cancelled` event.

In one shell, start a long-running request:

```bash
curl -N -X POST localhost:8080/v1/agents \
     -H 'X-API-Key: test-key' \
     -H 'Content-Type: application/json' \
     -d '{
       "model": "mock-claude",
       "messages": [{ "role": "user", "content": "use_tools please" }],
       "metadata": { "scenario": "tool_use" }
     }' &
```

Note the `session_id` from the first event. In another shell:

```bash
curl -X DELETE -H 'X-API-Key: test-key' \
     localhost:8080/v1/sessions/<paste-session-id-here>
# → 204 No Content
```

The first shell should see a `cancelled` event before the next `turn_start`,
and then `end`. Confirm `agent_mux_sessions_total{status="cancelled"}` ticks
in `/metrics`.

## Scenario 7 — token budget

**What it tests:** Redis-backed `budget_check` script, atomic INCRBY against
the per-session limit, fail-open on Redis miss.

Send a request with a tiny budget:

```bash
curl -N -X POST localhost:8080/v1/agents \
     -H 'X-API-Key: test-key' \
     -H 'Content-Type: application/json' \
     -d '{
       "model": "mock-claude",
       "messages": [{ "role": "user", "content": "hello" }],
       "budget": { "max_tokens": 5 }
     }'
```

The mock's first turn alone uses more than 5 tokens, so the loop should emit:

```
event: done   { "stop_reason": "budget_exhausted", "turns": 1 }
```

`agent_mux_sessions_total{status="budget_exhausted"}` should increment by 1.

## Scenario 8 — per-IP rate limit

**What it tests:** `policy/ip_ratelimit.lua` token bucket against Redis,
returning 429 when the bucket is empty.

Bucket defaults are generous, so override on boot:

```bash
# kill the running demo first (Ctrl+C in the demo shell), then:
AGENT_MUX_API_KEYS=test-key \
AGENT_MUX_IP_BUCKET_CAPACITY=3 \
AGENT_MUX_IP_REFILL_PER_SEC=0 \
make demo
```

Hammer it:

```bash
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "request $i: HTTP %{http_code}\n" \
       -X POST -H 'X-API-Key: test-key' -H 'Content-Type: application/json' \
       -d '{"model":"mock-claude","messages":[{"role":"user","content":"hi"}]}' \
       localhost:8080/v1/agents
done
```

Expect the first 3 to return `200`, the next 2 `429`.

## Scenario 9 — graceful shutdown

**What it tests:** `server.lua`'s shutdown handler emits a final `done` event
on every in-flight session before nginx exits.

Start a long request in one shell (use the tool-use scenario from §4 so it
takes more than a moment), then in another shell:

```bash
openresty -p "$PWD/" -c "$PWD/conf/nginx.conf" -s quit
```

The first shell should see a `done` event with `stop_reason = "shutdown"`
(or similar) and the connection close cleanly — *not* a TCP reset.

## Verifying observability

After running scenarios 3–8, scrape metrics:

```bash
curl -fsS localhost:8080/metrics | grep -E '^agent_mux_' | grep -v '^#'
```

You should see non-zero values for:

- `agent_mux_sessions_total{status="…"}` — at least `started`, `end_turn`,
  and whichever of `cancelled` / `budget_exhausted` you triggered.
- `agent_mux_turns_total{model="mock-claude",stop_reason="…"}`
- `agent_mux_tool_calls_total{name="calculator|search",outcome="ok|error"}`
- `agent_mux_llm_latency_seconds_bucket{…}` — non-zero `_count`.
- `agent_mux_tool_latency_seconds_bucket{…}` — non-zero `_count`.

Tail the request log to see the structured per-request line emitted by
`observability/log.lua`:

```bash
tail -f logs/error.log | grep '"event":"request"'
```

Each line is one JSON object with `uri`, `status`, `latency_ms`, `event`.

If `AGENT_MUX_HOOKS_DIR` is unset (default `examples/hooks`), the audit hook
also logs every tool call:

```bash
tail -f logs/error.log | grep audit
```

## Cleanup

```bash
# In the demo shell: Ctrl+C
# Then, if anything's still bound:
make stop
make clean   # clears logs/ and run/
```

Confirm nothing is still listening:

```bash
lsof -iTCP:8080 -sTCP:LISTEN
lsof -iTCP:6390 -sTCP:LISTEN
```

Both should be silent.
