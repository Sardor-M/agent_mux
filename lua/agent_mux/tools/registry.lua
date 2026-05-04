-- tools/registry.lua  —  the tool catalogue.
--
-- Stub for v0.1 scaffolding. Real implementation lands in week 2.
-- See docs/IMPLEMENTATION_PLAN.md §8.
--
-- Three handler flavours plug in here:
--   inline  — Lua function in-process              (tools/inline.lua)
--   http    — POST to a configured URL             (tools/http.lua)
--   mcp     — JSON-RPC to an MCP server (stdio/SSE) (tools/mcp.lua)
--
-- Public surface (planned):
--   register(manifest)     - manifest = { name, description, schema, run, timeout_ms, ... }
--   get(name)              → manifest | nil
--   list()                 → array of manifests (for tools/list MCP responses)
--   bootstrap(config)      — load inline modules + HTTP manifests + start MCP clients

local _M = {}

local _tools = {}

function _M.register(manifest)
    assert(manifest and manifest.name, "tool manifest must have a name")
    _tools[manifest.name] = manifest
end

function _M.get(name)
    return _tools[name]
end

function _M.list()
    local out = {}
    for _, m in pairs(_tools) do out[#out + 1] = m end
    return out
end

function _M.bootstrap(_config)
    -- Real bootstrap arrives in week 2 — load inline tool files,
    -- read HTTP manifest JSON, spawn MCP clients via tools/mcp.lua.
end

-- Test hook.
function _M._reset_for_test()
    _tools = {}
end

return _M
