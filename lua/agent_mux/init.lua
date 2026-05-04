-- agent_mux  —  module entry.
--
-- This file is the single public surface. Other modules are loaded
-- on-demand from the request phases. Keep this small.

local _M = {
    _VERSION = "0.1.0-dev",
    _NAME    = "agent_mux",
}

-- Called once per nginx worker from `init_worker_by_lua_block`.
-- Anything that should be done before the first request lives here:
--   - Redis script registration (SCRIPT LOAD → SHA cache)
--   - Hook directory load
--   - Tool registry warm-up (inline + HTTP manifests)
--   - Metrics counter initialisation
--
-- Failures here prevent the worker from accepting traffic — that is the
-- point. We would rather fail to start than serve traffic with a half-
-- initialised registry.
function _M.init_worker()
    local ok, err = pcall(function()
        require("agent_mux.observability.metrics").init()
        -- redis_client.init() and tools.registry.bootstrap() land in week 1
        -- when those modules are filled in.
    end)
    if not ok then
        ngx.log(ngx.ERR, "agent_mux init_worker failed: ", err)
    end
end

return _M
