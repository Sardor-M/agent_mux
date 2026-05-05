-- session/concurrency.lua  —  per-org max-concurrent-sessions guard.
--
-- Claim is called from server.access() before the agent loop starts;
-- release is called from server.log_phase() so it runs whether the loop
-- ended normally, with an error, or was cancelled.
--
-- The "org" axis is whatever the caller put in `session.org_id`. If
-- absent, we use a global bucket — useful for v0.1 single-tenant runs.

local redis = require("agent_mux.redis_client")

local _M = {}

local DEFAULT_MAX = 16            -- per-org cap
local DEFAULT_TTL_MS = 600000     -- 10min: a session that's been silent this long has crashed

local function key_for(session)
    local org = (session.org_id and session.org_id ~= "") and session.org_id or "_global"
    return "concurrency:org:" .. org
end

-- Returns: claimed (boolean), current_count
function _M.claim(session, opts)
    opts = opts or {}
    local max_concurrent = opts.max or DEFAULT_MAX
    local ttl_ms         = opts.ttl_ms or DEFAULT_TTL_MS

    local res, err = redis.run("concurrency_claim",
        { key_for(session) },
        { session.id, max_concurrent, ngx.now() * 1000, ttl_ms })

    if not res then
        ngx.log(ngx.WARN, "concurrency_claim script failed (fail-open): ", err)
        return true, 0
    end

    local claimed       = (tonumber(res[1]) == 1)
    local current_count = tonumber(res[2]) or 0
    return claimed, current_count
end

function _M.release(session)
    local res, err = redis.run("concurrency_release",
        { key_for(session) },
        { session.id })

    if not res then
        ngx.log(ngx.WARN, "concurrency_release script failed: ", err)
        return false
    end
    return true
end

return _M
