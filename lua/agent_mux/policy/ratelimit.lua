-- policy/ratelimit.lua  —  per-(session, tool) token bucket wrapper.
--
-- Thin layer over scripts/tool_ratelimit.lua. The dispatcher calls
-- `try_consume(session, tool_name, manifest)` before invoking a tool
-- handler. If the bucket is empty, the dispatcher synthesises a typed
-- tool_result with is_error=true and "rate_limited" content.
--
-- Per-tool capacity / refill rate come from the manifest (with defaults).
-- This keeps tool authors in control of their tool's call ceiling without
-- needing global config plumbing.

local redis = require("agent_mux.redis_client")

local _M = {}

local DEFAULT_CAPACITY    = 30      -- bucket size; allows a small burst
local DEFAULT_REFILL_RATE = 5       -- tokens/sec; sustained 5 calls/sec

-- Returns: allowed (boolean), remaining (number), retry_after_ms (number)
function _M.try_consume(session, tool_name, manifest)
    local capacity    = (manifest and manifest.rate_limit_capacity)    or DEFAULT_CAPACITY
    local refill_rate = (manifest and manifest.rate_limit_refill_rate) or DEFAULT_REFILL_RATE
    local key         = ("ratelimit:tool:%s:%s"):format(session.id, tool_name)
    local now_ms      = ngx.now() * 1000

    local res, err = redis.run("tool_ratelimit",
        { key },
        { capacity, refill_rate, now_ms, 1 })

    if not res then
        -- Fail-open if Redis is unavailable. Same posture as the monthly
        -- quota in m365-fastapi-backend: a soft business control should
        -- not take chat down with it.
        ngx.log(ngx.WARN, "tool_ratelimit script failed (fail-open): ", err)
        require("agent_mux.observability.metrics")
            .inc("agent_mux_fail_open_total", { component = "tool_ratelimit" })
        return true, capacity, 0
    end

    local allowed        = (tonumber(res[1]) == 1)
    local remaining      = tonumber(res[2]) or 0
    local retry_after_ms = tonumber(res[3]) or 0
    return allowed, remaining, retry_after_ms
end

return _M
