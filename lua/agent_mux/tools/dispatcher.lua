-- tools/dispatcher.lua  —  concurrent execution of tool_use blocks.
--
-- When the upstream model emits N `tool_use` blocks in a single assistant
-- turn, we run them in parallel via `ngx.thread.spawn`. The model is
-- already finished when we get here; the wall-clock time of the next
-- LLM turn is gated by `max(per-tool latency)`, not the sum.
--
-- Output shape (per tool) returned to the agent loop:
--
--   { tool_use_id = "...", content = "<string>", is_error = nil|true }
--
-- which the loop hands to session.messages.user_with_tool_results to
-- build the next user turn.
--
-- SSE event vocabulary (in order, per call):
--   tool_call           — id, name, input
--   tool_result         — id, name, content, is_error, latency_ms
-- Wrapper events (once per dispatch batch):
--   tool_dispatch_start    count
--   tool_dispatch_complete count, errors

local registry  = require("agent_mux.tools.registry")
local auth      = require("agent_mux.policy.auth")
local ratelimit = require("agent_mux.policy.ratelimit")
local metrics   = require("agent_mux.observability.metrics")
local log       = require("agent_mux.observability.log")

local _M = {}

local function now_ms()
    return ngx.now() * 1000
end

-- Run one tool_use block. Returns the tool_result table.
local function run_one(session, use, sse)
    local started = now_ms()

    sse:emit("tool_call", {
        id    = use.id,
        name  = use.name,
        input = use.input,
    })

    -- 1) Resolve manifest.
    local manifest = registry.get(use.name)
    if not manifest then
        local out = {
            tool_use_id = use.id,
            content     = "tool not registered: " .. tostring(use.name),
            is_error    = true,
        }
        sse:emit("tool_result", {
            id          = use.id,
            name        = use.name,
            content     = out.content,
            is_error    = true,
            latency_ms  = now_ms() - started,
        })
        metrics.inc("agent_mux_tool_calls_total",
            { name = use.name, outcome = "not_registered" })
        return out
    end

    -- 2) Authorisation via policy/auth.lua. Reads session.tool_policy
    -- and applies allow/deny resolution rules.
    local allowed, reason = auth.check(session, use.name)
    if not allowed then
        local out = {
            tool_use_id = use.id,
            content     = "permission_denied: " .. tostring(reason),
            is_error    = true,
        }
        sse:emit("tool_result", {
            id          = use.id, name = use.name,
            content     = out.content, is_error = true,
            latency_ms  = now_ms() - started,
        })
        metrics.inc("agent_mux_tool_calls_total",
            { name = use.name, outcome = "denied" })
        return out
    end

    -- 2b) Rate limit via Redis Lua token bucket. Per (session, tool).
    local rl_ok, rl_remaining, rl_retry_ms = ratelimit.try_consume(session, use.name, manifest)
    if not rl_ok then
        local out = {
            tool_use_id = use.id,
            content     = ("rate_limited: retry after %d ms"):format(rl_retry_ms),
            is_error    = true,
        }
        sse:emit("tool_result", {
            id             = use.id, name = use.name,
            content        = out.content, is_error = true,
            latency_ms     = now_ms() - started,
            retry_after_ms = rl_retry_ms,
            remaining      = rl_remaining,
        })
        metrics.inc("agent_mux_tool_calls_total",
            { name = use.name, outcome = "rate_limited" })
        return out
    end

    -- 3) Execute. pcall contains a buggy handler so it cannot kill the loop.
    local ok, result = pcall(manifest.run, use.input, {
        session     = session,
        deadline_ms = manifest.timeout_ms,
    })

    local out
    if not ok then
        log.warn("tool_handler_error", {
            tool = use.name, session_id = session.id, err = tostring(result),
        })
        out = {
            tool_use_id = use.id,
            content     = "handler_error: " .. tostring(result),
            is_error    = true,
        }
    elseif type(result) ~= "table" then
        -- Convenience: a handler that returns a bare string is treated as
        -- a successful text result.
        out = {
            tool_use_id = use.id,
            content     = tostring(result),
            is_error    = nil,
        }
    else
        out = {
            tool_use_id = use.id,
            content     = result.content or "",
            is_error    = result.is_error and true or nil,
        }
    end

    sse:emit("tool_result", {
        id          = use.id,
        name        = use.name,
        content     = out.content,
        is_error    = out.is_error and true or nil,
        latency_ms  = now_ms() - started,
    })

    metrics.inc("agent_mux_tool_calls_total", {
        name    = use.name,
        outcome = out.is_error and "error" or "ok",
    })
    return out
end

-- run_concurrent(session, tool_uses, sse) → array of tool_result tables.
--
-- Output preserves input order so the next user turn lists tool_results
-- in the same order the assistant emitted tool_use blocks. Anthropic
-- doesn't *require* this, but it makes transcripts readable.
function _M.run_concurrent(session, tool_uses, sse)
    sse:emit("tool_dispatch_start", { count = #tool_uses })

    local threads = {}
    for i, use in ipairs(tool_uses) do
        threads[i] = ngx.thread.spawn(run_one, session, use, sse)
    end

    local results, errors = {}, 0
    for i, th in ipairs(threads) do
        local ok, result = ngx.thread.wait(th)
        if not ok then
            -- ngx.thread reported a panic. Synthesize a tool_result so the
            -- model still sees a clean response (handlers must not abort
            -- the loop).
            results[i] = {
                tool_use_id = tool_uses[i].id,
                content     = "thread_panic: " .. tostring(result),
                is_error    = true,
            }
            errors = errors + 1
        else
            if result.is_error then errors = errors + 1 end
            results[i] = result
        end
    end

    sse:emit("tool_dispatch_complete", {
        count  = #tool_uses,
        errors = errors,
    })
    return results
end

-- Test hook: synchronous dispatch for the busted suite. Identical
-- semantics to run_concurrent but uses a stubbable internal so tests
-- can avoid ngx.thread entirely.
function _M._run_synchronous(session, tool_uses, sse)
    sse:emit("tool_dispatch_start", { count = #tool_uses })
    local results, errors = {}, 0
    for i, use in ipairs(tool_uses) do
        local r = run_one(session, use, sse)
        results[i] = r
        if r.is_error then errors = errors + 1 end
    end
    sse:emit("tool_dispatch_complete", { count = #tool_uses, errors = errors })
    return results
end

_M._run_one = run_one
return _M
