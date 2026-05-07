# AgentMux

A small, fast **agent harness** built on OpenResty/LuaJIT. It runs multi-turn
LLM agent loops in a single nginx worker — streaming SSE to the client,
dispatching tool calls (inline, HTTP, or MCP over JSON-RPC), and persisting
session state in Redis.

The point is to keep the loop, the tool plane, and the transport in one
process so latency stays in the millisecond range and the operational surface
stays small. No queue, no scheduler, no microservices — just nginx phases,
cosockets, and Redis.

## What works today

- Multi-turn agent loop with a wall-clock timeout per session
- Streaming Anthropic upstream + a mock upstream for local dev and tests
- Tool dispatch — inline Lua, HTTP tools, and MCP servers spawned over stdio
- Concurrent fan-out for tool calls inside one assistant turn
- Sessions in Redis with cancellation (`DELETE /v1/sessions/:id`), per-session
  token budgets, per-org concurrency slots, and a schema migration framework
- Hooks runtime with hot reload — pre/post LLM and pre/post tool fire-points
- API-key auth, per-IP rate limit, per-tool rate limit, tool authorisation
- Prometheus metrics, OpenTelemetry spans, structured request logs
- Graceful shutdown that drains in-flight sessions and emits a final `done`
  event before the worker exits
- Request body size pre-check, redis health gauge, fail-open audit counter
- CI on GitHub Actions (busted suite + redis), Claude PR review workflow

## Run it locally

```bash
make check-deps         # verify openresty + redis are on PATH
make demo               # boots redis and OpenResty together for an end-to-end run
```

If you want to manage redis yourself:

```bash
make dev                # OpenResty in foreground on :8080
```

Sanity-check it:

```bash
curl localhost:8080/healthz                    # → ok
curl localhost:8080/metrics                    # Prometheus exposition
curl -N -X POST localhost:8080/v1/agents \
     -H 'content-type: application/json' \
     --data @examples/agent_request.json       # streams SSE
```

`Ctrl+C` to stop. `make stop` if you backgrounded it.

## HTTP routes

| Route                         | What it does                                          |
|-------------------------------|-------------------------------------------------------|
| `POST /v1/agents`             | Start an agent run; streams SSE deltas + tool events  |
| `DELETE /v1/sessions/:id`     | Cancel an in-flight session gracefully                |
| `GET  /healthz`               | Liveness check + redis health probe                   |
| `GET  /metrics`               | Prometheus exposition                                 |
| `POST /mock/v1/messages`      | Local mock upstream for tests and the demo            |

## Layout

```
conf/nginx.conf                OpenResty config — locations, phases, package path
lua/agent_mux/
  ├─ server.lua                access / content / log phases, graceful shutdown
  ├─ agent_loop.lua            the multi-turn loop
  ├─ errors.lua                shared error taxonomy
  ├─ redis_client.lua          pooled cosocket client
  ├─ upstream/                 Anthropic streaming client + SSE chunk parser
  ├─ tools/                    registry, dispatcher, inline / HTTP / MCP handlers
  ├─ transport/                SSE encoder, JSON-RPC 2.0 framing for MCP stdio
  ├─ session/                  store, messages, budget, concurrency, migrations
  ├─ hooks/                    runtime + loader for pre/post LLM and pre/post tool
  ├─ observability/            log, Prometheus metrics, OpenTelemetry spans
  ├─ policy/                   API-key auth, IP rate limit, tool rate limit + authz
  └─ scripts/                  atomic Redis Lua scripts (budget, concurrency, RL)
examples/                      mock upstream, sample tools, sample hooks, request body
tests/                         busted unit + integration suite
bench/                         wrk harness + baseline output
```

The `docs/` tree has longer write-ups for each subsystem if you want the why,
not just the what.

## Prerequisites

- **OpenResty 1.25+** — `brew install openresty/brew/openresty`
- **Redis 7+** — `brew install redis`
- **busted** for tests — `luarocks install busted`
- Optional: `wrk` for benchmarks, `stylua` for formatting

## Useful targets

```bash
make help               # list everything
make test               # busted unit + integration suite
make bench              # wrk against /healthz, /metrics, /v1/agents
make fmt                # stylua (if installed)
make clean              # clear logs/ and run/
```

## License

TBD.
