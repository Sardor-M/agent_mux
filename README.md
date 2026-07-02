# agent_mux

> **agent_mux runs your MCP servers in production — with auth, budgets,
> rate limits, lifecycle, and observability — so you don't have to.**

Most teams adopting MCP end up rebuilding the same operational scaffolding:
spawn the server, watch it crash, restart with backoff, route JSON-RPC, gate
with auth, enforce per-tenant quotas, log every call, kill on budget breach.
agent_mux is that scaffolding, shipped — a single OpenResty/LuaJIT process that
supervises a fleet of MCP servers and exposes them through one streaming agent
endpoint.

The agent loop, the policy plane, and the MCP transport all live in the same
worker, so latency stays in the millisecond range and the operational surface
stays small. No queue, no scheduler, no microservices.

## What you get

**MCP supervision**
- Subprocess lifecycle for stdio MCP servers — spawn, monitor, **respawn with
  exponential backoff** on crash
- JSON-RPC 2.0 framing over the stdio pipe
- Tools from MCP servers join the same registry as inline Lua tools and HTTP
  tools, behind one dispatcher
- The same auth / per-tool rate limit / per-org concurrency / token budget
  apply to MCP tool calls as to any other tool — no MCP-shaped policy holes

**Agent runtime around it**
- Multi-turn agent loop with a wall-clock timeout per session
- Streaming Anthropic upstream (+ a mock upstream for local dev) returning
  Server-Sent Events
- Concurrent fan-out for tool calls inside a single assistant turn
- Sessions in Redis with cancellation (`DELETE /v1/sessions/:id`),
  per-session token budgets, per-org concurrency slots, schema migrations
- Hooks runtime (pre/post LLM, pre/post tool) with hot reload — drop a Lua
  file in `AGENT_MUX_HOOKS_DIR` and it picks up on next request

**Operations**
- API-key auth, per-IP rate limit, per-tool rate limit, tool authorisation
- Prometheus metrics, OpenTelemetry spans, structured request logs
- Graceful shutdown that drains in-flight sessions and emits a final `done`
  event before the worker exits
- Request body size pre-check, redis health gauge, fail-open audit counter

## Quick start

```bash
make check-deps                                    # openresty + redis on PATH
export AGENT_MUX_API_KEYS=test-key
export AGENT_MUX_MCP_FILE=examples/tools/mcp_servers.json
make demo                                          # boots redis + OpenResty
```

This boots redis on `:6390`, OpenResty on `:8080`, and supervises the demo
MCP server (a Python stdio server in `examples/tools/mcp_demo/`).

In a second terminal:

```bash
curl localhost:8080/healthz                        # → ok
curl localhost:8080/metrics | grep agent_mux       # Prometheus exposition

curl -N -X POST localhost:8080/v1/agents \
     -H 'X-API-Key: test-key' \
     -H 'Content-Type: application/json' \
     --data @examples/agent_request.json           # streams SSE
```

## Use it as an MCP gateway

Point Claude Code and Codex at agent_mux instead of wiring each MCP server
into each client separately. Every inline, HTTP, and supervised MCP tool is
exposed through one endpoint, and every `tools/call` runs the same auth →
per-tool rate limit → hooks → metrics path as the agent loop. The result is
one supervised, observable, policy-enforced MCP surface shared across every
coding agent you point at it — with a single place to see what your agents
actually called.

Boot agent_mux with your MCP manifest:

```bash
export AGENT_MUX_API_KEYS=test-key
export AGENT_MUX_MCP_FILE=examples/tools/mcp_servers.json
make demo
```

**Claude Code / Codex (HTTP transport)** — add to `.mcp.json`:

```jsonc
{
  "mcpServers": {
    "mux": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "headers": { "X-API-Key": "test-key" }
    }
  }
}
```

**stdio-only clients** — use the bundled bridge instead:

```jsonc
{
  "mcpServers": {
    "mux": {
      "command": "/abs/path/to/agent_mux/bin/agent-mux-mcp",
      "env": {
        "AGENT_MUX_MCP_URL": "http://localhost:8080/mcp",
        "AGENT_MUX_API_KEY": "test-key"
      }
    }
  }
}
```

Watch the fleet while your agents work:

```bash
make status        # one-shot table
make watch         # live-refreshing view, leave it open next to your editor
curl localhost:8080/v1/mcp/servers | jq   # JSON, for a dashboard
```

Inside Claude Code, the `/mcp-status` command summarises the same fleet.

## HTTP surface

| Route                          | Purpose                                                    |
|--------------------------------|------------------------------------------------------------|
| `POST /v1/agents`              | Start an agent run; streams SSE deltas + tool events       |
| `POST /mcp`                    | Northbound MCP gateway (Streamable-HTTP) for MCP clients    |
| `GET  /v1/mcp/servers`         | Supervised MCP server status (JSON, or `?format=text`)     |
| `DELETE /v1/sessions/:id`      | Cancel an in-flight session gracefully                     |
| `GET  /healthz`                | Liveness check + redis health probe                        |
| `GET  /metrics`                | Prometheus exposition                                      |
| `POST /mock/v1/messages`       | Local mock upstream for tests and demos                    |

## Layout

```
conf/nginx.conf                OpenResty config — env, locations, phases
lua/agent_mux/
  ├─ tools/                    registry, dispatcher, inline / HTTP / MCP handlers
  │   └─ mcp.lua               stdio MCP client + subprocess respawn + supervisor
  ├─ gateway/
  │   └─ mcp_server.lua        northbound MCP server (agent_mux as a gateway)
  ├─ transport/
  │   ├─ jsonrpc.lua           JSON-RPC 2.0 framing for MCP stdio
  │   └─ sse.lua               SSE encoder for client responses
  ├─ agent_loop.lua            the multi-turn loop
  ├─ server.lua                access / content / log phases, graceful shutdown
  ├─ session/                  store, messages, budget, concurrency, migrations
  ├─ hooks/                    pre/post LLM and pre/post tool runtime + loader
  ├─ observability/            log, Prometheus metrics, OpenTelemetry spans
  ├─ policy/                   API-key auth, IP rate limit, tool rate limit + authz
  ├─ upstream/                 LLM clients (Anthropic streaming, SSE chunk parser)
  ├─ scripts/                  atomic Redis Lua scripts (budget, concurrency, RL)
  ├─ redis_client.lua          pooled cosocket client + script registry
  └─ errors.lua                shared error taxonomy
bin/agent-mux-mcp              stdio↔HTTP bridge for stdio-only MCP clients
scripts/agent-mux-status.sh    CLI status view (make status / make watch)
examples/
  ├─ tools/mcp_demo/           stdio MCP server in Python — supervised by agent_mux
  ├─ tools/mcp_servers.json    MCP manifest the supervisor reads
  ├─ tools/inline_calculator.lua, http_search/, http_tools.json
  └─ hooks/audit_log.lua       reference audit hook
tests/                         busted unit + integration suite (85 tests)
bench/                         wrk harness + baseline output
```

## Prerequisites

- **OpenResty 1.25+** — `brew install openresty/brew/openresty`
- **Redis 7+** — `brew install redis`
- **busted** for tests — `luarocks install busted`
- **`lua-resty-http`** — not bundled with OpenResty; install via
  `opm get ledgetech/lua-resty-http`
- **Python 3.10+** if you want to run the demo MCP server
- Optional: `wrk` for benchmarks, `stylua` for formatting

## Useful targets

```bash
make help               # list everything
make demo               # boot redis + OpenResty for an end-to-end run
make dev                # OpenResty in foreground (you bring redis)
make test               # busted unit + integration suite
make bench              # wrk against /healthz, /metrics, /v1/agents
make stop               # stop a backgrounded OpenResty
make clean              # clear logs/ and run/
```

## What's next

Honest list of the gaps between what's shipped and full "MCP fleet manager"
parity. None of these block the use cases above; they're the work that turns
agent_mux into something an operations team can manage as a first-class
service:

- **Hot-reload of `AGENT_MUX_MCP_FILE`** — add or replace an MCP server
  without `make stop && make dev`.
- **Per-MCP-server resource caps** — memory ceiling, max concurrent calls,
  idle-timeout-then-respawn. Crash recovery (`feat(mcp): subprocess respawn
  with exponential backoff`) is in; proactive bounds aren't.
- **Live MCP traffic tail** — `GET /v1/mcp/servers/<name>/calls` (SSE) so
  operators can watch a server in real time.
- **`Dockerfile` + `docker-compose.yaml`** — one image, redis sidecar,
  configurable MCP manifest. Today, deployment is "install OpenResty +
  Redis, copy the repo, set env vars, run."
- **Thin client libraries** — Python and TypeScript wrappers around
  `/v1/agents` that yield SSE events as objects. Hand-rolling SSE in every
  integration is friction we should absorb.
- **More upstream providers** — only Anthropic today. OpenAI, Bedrock,
  Gemini adapters are mechanical work.

## License

MIT — see [`LICENSE`](LICENSE).
