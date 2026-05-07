-- policy/ip_ratelimit.lua  —  per-client-IP token bucket on /v1/agents.
--
-- Reuses scripts/tool_ratelimit.lua (same atomic refill+consume primitive)
-- with a different key shape: ratelimit:ip:<addr>. The handler is called
-- from server.access() before any Redis writes for the request, so a
-- flooder cannot create 1000 sessions/sec.
--
-- Defaults (overridable via env):
--   capacity            = 60     (small burst tolerated)
--   refill_per_second   = 1.0    (sustained 1 req/sec per IP)

local redis = require("agent_mux.redis_client")

local _M = {}

local DEFAULT_CAPACITY    = tonumber(os.getenv("AGENT_MUX_IP_BUCKET_CAPACITY")) or 60
local DEFAULT_REFILL_RATE = tonumber(os.getenv("AGENT_MUX_IP_REFILL_PER_SEC"))  or 1.0

-- Pull the client IP from the standard sources. nginx puts the direct
-- TCP peer in `ngx.var.remote_addr`; X-Forwarded-For (when present) is
-- preferred so a deployment behind a trusted reverse proxy works. The
-- operator must ensure XFF is only honoured from trusted hops in nginx
-- config — we don't try to validate that here.
local function client_ip()
    local xff = ngx.var.http_x_forwarded_for
    if xff and xff ~= "" then
        -- Take the leftmost — that's the original client.
        local first = xff:match("([^,]+)")
        if first then return (first:gsub("%s+", "")) end
    end
    return ngx.var.remote_addr or "0.0.0.0"
end

-- Returns: allowed (boolean), retry_after_ms (number), remaining (number)
function _M.check()
    local key = "ratelimit:ip:" .. client_ip()
    local now_ms = ngx.now() * 1000

    local res, err = redis.run("tool_ratelimit",
        { key },
        { DEFAULT_CAPACITY, DEFAULT_REFILL_RATE, now_ms, 1 })

    if not res then
        -- Fail-open. Same posture as every other Redis-backed policy.
        ngx.log(ngx.WARN, "ip_ratelimit script failed (fail-open): ", err)
        require("agent_mux.observability.metrics")
            .inc("agent_mux_fail_open_total", { component = "ip_ratelimit" })
        return true, 0, DEFAULT_CAPACITY
    end

    local allowed        = (tonumber(res[1]) == 1)
    local remaining      = tonumber(res[2]) or 0
    local retry_after_ms = tonumber(res[3]) or 0
    return allowed, retry_after_ms, remaining
end

_M._client_ip = client_ip
return _M
