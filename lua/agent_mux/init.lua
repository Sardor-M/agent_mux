-- agent_mux  —  module entry.
--
-- This file is the single public surface. Other modules are loaded
-- on-demand from the request phases. Keep this small.

local _M = {
    _VERSION = "0.2.0-dev",
    _NAME    = "agent_mux",
}

-- Default bootstrap config. Overridable by the operator via env vars
-- (week 3 will introduce a proper config file).
local function default_config()
    return {
        inline = {
            dirs = {
                os.getenv("AGENT_MUX_INLINE_TOOLS_DIR") or "examples/tools",
            },
        },
        http = {
            manifests = {
                os.getenv("AGENT_MUX_HTTP_TOOLS_FILE") or "examples/tools/http_tools.json",
            },
        },
    }
end

-- Called once per nginx worker from `init_worker_by_lua_block`.
-- Failures here prevent the worker from accepting traffic — that is the
-- point. We would rather fail to start than serve traffic with a half-
-- initialised registry.
function _M.init_worker()
    local ok, err = pcall(function()
        require("agent_mux.observability.metrics").init()
        require("agent_mux.tools.registry").bootstrap(default_config())
    end)
    if not ok then
        ngx.log(ngx.ERR, "agent_mux init_worker failed: ", err)
    end
end

return _M
