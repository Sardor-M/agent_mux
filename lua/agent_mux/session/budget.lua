-- session/budget.lua  —  per-session token budget enforcement.
--
-- Called from agent_loop after each upstream response, *before* the next
-- turn starts. If `consume(session, tokens)` returns false, the loop
-- terminates with stop_reason="budget_exhausted".
--
-- The session.budget shape is set up at create-time in session/store.lua:
--   session.budget = { max_tokens = 200000, wall_clock_ms = 600000 }

local redis = require("agent_mux.redis_client")

local _M = {}

local DEFAULT_TTL_SECONDS = 86400  -- 24h, matches session TTL after completion

-- Try to consume `tokens` from the session's budget. Returns
--   allowed   (boolean)
--   used      (running total after this call, or before if denied)
--   remaining (max_tokens - used)
function _M.try_consume(session, tokens)
    local max_tokens = session.budget and session.budget.max_tokens
    if not max_tokens or max_tokens <= 0 then
        -- No cap configured; pass through.
        return true, 0, math.huge
    end

    if tokens <= 0 then
        return true, 0, max_tokens
    end

    local key = "budget:session:" .. session.id
    local res, err = redis.run("budget_check",
        { key },
        { max_tokens, tokens, DEFAULT_TTL_SECONDS })

    if not res then
        -- Fail-open: do not let Redis flap take down chat.
        ngx.log(ngx.WARN, "budget_check script failed (fail-open): ", err)
        require("agent_mux.observability.metrics")
            .inc("agent_mux_fail_open_total", { component = "session_budget" })
        return true, 0, max_tokens
    end

    local allowed   = (tonumber(res[1]) == 1)
    local used      = tonumber(res[2]) or 0
    local remaining = tonumber(res[3]) or 0
    return allowed, used, remaining
end

-- Read-only inspection — used by /v1/sessions/:id rendering.
function _M.peek(session)
    local max_tokens = session.budget and session.budget.max_tokens
    if not max_tokens then return nil end

    local r, err = redis.connect()
    if not r then return nil end
    local raw = r:get("budget:session:" .. session.id)
    redis.release(r)

    local used = tonumber(raw) or 0
    return { used = used, remaining = max_tokens - used, max_tokens = max_tokens }
end

return _M
