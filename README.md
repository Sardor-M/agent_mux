# AgentMux

A practical, low-latency **agent harness** in Lua/OpenResty. Drives multi-turn
LLM agent loops with pluggable tool dispatch (inline / HTTP / MCP), session
state with resumability, hot-reloadable hooks, structured observability, and
streaming SSE — all in one OpenResty/LuaJIT process.

> Status: **scaffolding** (pre-v0.1). The directory layout, build system, and
> request entry points exist; the agent loop and tool dispatch land in

## Quickstart

```bash
make check-deps    # verify openresty + redis on PATH
make dev           # boot OpenResty in foreground on :8080
curl localhost:8080/healthz   # → ok
```

Stop with `Ctrl+C`.

## What's where

```
conf/nginx.conf            OpenResty config (lua_package_path, locations, phases)
lua/agent_mux/             All Lua source — public surface in init.lua
  ├─ server.lua            access/content/log phase glue
  ├─ agent_loop.lua        the multi-turn loop (Week 1)
  ├─ upstream/             LLM provider clients (Anthropic, OpenAI, ...)
  ├─ tools/                tool registry + dispatcher (inline/HTTP/MCP)
  ├─ session/              Redis-backed session state
  ├─ hooks/                pre/post hook runtime + hot-reload
  ├─ transport/            SSE encoder, JSON-RPC framing for MCP
  ├─ observability/        log, metrics, spans
  └─ policy/               auth + per-tool rate limit
examples/                  mock upstream, sample tools, sample hooks
tests/                     busted unit + integration tests
scripts/                   demo launcher, dep check
```

## Prerequisites

- **OpenResty 1.25+** (`brew install openresty/brew/openresty`)
- **Redis 7+** (`brew install redis`)
- **busted** for tests (`luarocks install busted`)
- Optional: `wrk` for benchmarks, `stylua` for formatting

## License

TBD.
