package = "agent-mux"
version = "dev-1"

source = {
    url = "git+https://github.com/example/agent_mux.git",
}

description = {
    summary  = "A practical, low-latency agent harness in Lua/OpenResty.",
    detailed = [[
Multi-turn LLM agent loops with pluggable tool dispatch (inline / HTTP / MCP),
session resumability, hot-reloadable hooks, and streaming SSE — all in one
OpenResty/LuaJIT process.
    ]],
    homepage = "https://github.com/example/agent_mux",
    license  = "TBD",
}

dependencies = {
    "lua >= 5.1, < 5.5",
    "lua-cjson >= 2.1",
    "lua-resty-http >= 0.17",
    -- lua-resty-redis ships with OpenResty
    -- busted is a dev-only dep, not declared here
}

build = {
    type    = "builtin",
    modules = {
        ["agent_mux.init"]                       = "lua/agent_mux/init.lua",
        ["agent_mux.server"]                     = "lua/agent_mux/server.lua",
        ["agent_mux.errors"]                     = "lua/agent_mux/errors.lua",
        ["agent_mux.redis_client"]               = "lua/agent_mux/redis_client.lua",
        ["agent_mux.agent_loop"]                 = "lua/agent_mux/agent_loop.lua",
        ["agent_mux.session.store"]              = "lua/agent_mux/session/store.lua",
        ["agent_mux.tools.registry"]             = "lua/agent_mux/tools/registry.lua",
        ["agent_mux.transport.sse"]              = "lua/agent_mux/transport/sse.lua",
        ["agent_mux.observability.log"]          = "lua/agent_mux/observability/log.lua",
        ["agent_mux.observability.metrics"]      = "lua/agent_mux/observability/metrics.lua",
    },
}
