-- tools/registry.lua  —  the tool catalogue.
--
-- Hands out tool manifests to the dispatcher. The dispatcher does not
-- care whether a tool is implemented inline, over HTTP, or via MCP —
-- every manifest exposes the same surface:
--
--   {
--       name         = "calculator",          -- LLM-visible identifier
--       description  = "...",                  -- LLM-visible
--       schema       = { ... },                -- JSON Schema for input
--       timeout_ms   = 100,                    -- per-call wall-clock budget
--       run          = function(input, ctx)    -- returns { content, is_error? }
--                          ...
--                      end,
--       _origin      = "inline" | "http" | "mcp",   -- diagnostic only
--   }
--
-- For LLM-side advertisement (what we send Anthropic in `tools`), the
-- caller can do `to_api_schema(name)` and get the {name, description,
-- input_schema} triple Anthropic expects. That keeps wire-shape concerns
-- out of every callsite.

local _M = {}

local _tools = {}

-- Validate the minimum required keys before we accept a manifest. Bad
-- manifests should fail at registration time, not on the hot path.
local function check_manifest(m)
    if type(m)            ~= "table"    then return "not a table" end
    if type(m.name)       ~= "string"   then return "name: string required" end
    if type(m.description)~= "string"   then return "description: string required" end
    if type(m.schema)     ~= "table"    then return "schema: table required" end
    if type(m.run)        ~= "function" then return "run: function required" end
    if m.timeout_ms ~= nil and type(m.timeout_ms) ~= "number" then
        return "timeout_ms: number"
    end
    return nil
end

function _M.register(manifest)
    local err = check_manifest(manifest)
    if err then
        error("tool manifest invalid for '" .. tostring(manifest and manifest.name) ..
              "': " .. err)
    end
    manifest.timeout_ms = manifest.timeout_ms or 5000
    _tools[manifest.name] = manifest
    return manifest
end

function _M.get(name) return _tools[name] end

function _M.list()
    local out = {}
    for _, m in pairs(_tools) do out[#out + 1] = m end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Project the registered tools into the array shape Anthropic expects in
-- request.tools. Strips local-only fields (run, timeout_ms, _origin).
function _M.to_api_schema()
    local out = {}
    for _, m in ipairs(_M.list()) do
        out[#out + 1] = {
            name         = m.name,
            description  = m.description,
            input_schema = m.schema,
        }
    end
    return out
end

-- Bootstrap the registry from an explicit config table. Called once per
-- worker from agent_mux.init_worker(). Layout:
--
--   {
--       inline = { dirs = { "examples/tools" } },
--       http   = { manifests = { "config/http_tools.json" } },
--       -- mcp = { ... }   week 3
--   }
--
-- Handlers are registered immediately. Errors in one source do not stop
-- registration of the others — log and continue.
function _M.bootstrap(config)
    config = config or {}
    if config.inline and config.inline.dirs then
        local inline = require("agent_mux.tools.inline")
        for _, dir in ipairs(config.inline.dirs) do
            local ok, err = pcall(inline.load_dir, dir)
            if not ok then
                ngx.log(ngx.WARN, "inline.load_dir(", dir, ") failed: ", err)
            end
        end
    end
    if config.http and config.http.manifests then
        local http = require("agent_mux.tools.http")
        for _, manifest_path in ipairs(config.http.manifests) do
            local ok, err = pcall(http.load_manifest, manifest_path)
            if not ok then
                ngx.log(ngx.WARN, "http.load_manifest(", manifest_path, ") failed: ", err)
            end
        end
    end
end

function _M._reset_for_test() _tools = {} end
_M._check_manifest = check_manifest

return _M
