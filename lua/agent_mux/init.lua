-- agent_mux  —  module entry.
--
-- This file is the single public surface. Other modules are loaded
-- on-demand from the request phases. Keep this small.

local _M = {
    _VERSION = "0.3.0-dev",
    _NAME    = "agent_mux",
}

-- Default bootstrap config. Overridable by the operator via env vars.
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
        mcp = {
            -- MCP is opt-in: set AGENT_MUX_MCP_FILE to a manifest path to enable.
            manifests = (function()
                local f = os.getenv("AGENT_MUX_MCP_FILE")
                return f and { f } or {}
            end)(),
        },
    }
end

-- Redis Lua scripts loaded into Redis once per worker. The redis_client
-- caches the SHA1 so subsequent requests use EVALSHA on the hot path.
local function redis_scripts()
    return {
        tool_ratelimit       = "lua/agent_mux/scripts/tool_ratelimit.lua",
        budget_check         = "lua/agent_mux/scripts/budget_check.lua",
        concurrency_claim    = "lua/agent_mux/scripts/concurrency_claim.lua",
        concurrency_release  = "lua/agent_mux/scripts/concurrency_release.lua",
    }
end

-- Called once per nginx worker from `init_worker_by_lua_block`.
-- Failures here prevent the worker from accepting traffic — that is the
-- point. We would rather fail to start than serve traffic with a half-
-- initialised registry.
function _M.init_worker()
    local ok, err = pcall(function()
        require("agent_mux.observability.metrics").init()
        require("agent_mux.policy.auth_request").init()
        require("agent_mux.tools.registry").bootstrap(default_config())

        -- Load hooks from the configured directory. AGENT_MUX_HOOKS_DIR
        -- can be empty / unset to disable hooks entirely.
        local hooks_dir = os.getenv("AGENT_MUX_HOOKS_DIR") or "examples/hooks"
        if hooks_dir ~= "" then
            require("agent_mux.hooks.loader").load_dir(hooks_dir)
        end

        -- Load Redis Lua scripts. Cosockets are disabled in
        -- init_worker_by_lua*, so defer the connect+SCRIPT LOAD via a
        -- zero-delay timer where they are allowed. We swallow Redis-down
        -- errors so a temporarily-unavailable Redis doesn't block the
        -- worker from starting; redis_client.run returns nil and our
        -- wrappers fail-open.
        local rc           = require("agent_mux.redis_client")
        local script_specs = redis_scripts()
        local sched_ok, sched_err = ngx.timer.at(0, function()
            local sok, serr = rc.load_scripts(script_specs)
            if not sok then
                ngx.log(ngx.WARN, "redis script load failed (will retry per-call): ", serr)
            end
        end)
        if not sched_ok then
            ngx.log(ngx.WARN, "could not schedule redis script load: ", sched_err)
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "agent_mux init_worker failed: ", err)
    end
end

return _M
