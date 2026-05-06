-- hooks/runtime.lua  —  the hook event bus.
--
-- Hooks are user-supplied Lua functions invoked at lifecycle points by
-- the agent_loop and the dispatcher. Each event has zero or more
-- registered handlers; `fire(event, payload)` calls them all in registration
-- order, contains errors with pcall, and **never blocks the loop**.
--
-- Supported events (from IMPL_PLAN §10):
--
--   pre_llm     — before each upstream.call. May mutate session.messages.
--   post_llm    — after each upstream response. Read-only.
--   pre_tool    — before each tool dispatch. May mutate use.input.
--   post_tool   — after each tool result. Read-only-by-convention.
--   on_error    — on any caught error during the run.
--   on_cancel   — on cancellation.
--   on_done     — on session completion (any terminal stop_reason).
--
-- Handler shape:
--   handler(event_name, payload) → nil | mutated payload
--
-- The runtime ignores return values for v0.1 — mutation is via direct
-- table writes on the payload (which is the session/use/response object).

local _M = {}

-- registry: { [event_name] = { { name = "...", run = fn }, ... } }
local _registry = {}

-- Stable registration order. Handlers added later run after earlier ones,
-- which lets a "redact" hook strip a field before "audit_log" sees it.
function _M.register(event_name, handler_table)
    assert(type(event_name) == "string", "event_name must be a string")
    assert(type(handler_table) == "table",   "handler_table must be a table")
    assert(type(handler_table.name) == "string", "handler.name required")
    assert(type(handler_table.run)  == "function", "handler.run required")

    _registry[event_name] = _registry[event_name] or {}
    table.insert(_registry[event_name], handler_table)
end

-- Fire all handlers for `event`. Each handler runs in pcall so a single
-- buggy hook cannot abort the loop. Returns the number of handlers that
-- ran successfully (vs erroring) for diagnostics.
function _M.fire(event_name, payload)
    local list = _registry[event_name]
    if not list or #list == 0 then return 0, 0 end

    local ok_count, err_count = 0, 0
    for _, h in ipairs(list) do
        local ok, err = pcall(h.run, event_name, payload)
        if ok then
            ok_count = ok_count + 1
        else
            err_count = err_count + 1
            ngx.log(ngx.WARN, "hook ", h.name, " on ", event_name, " errored: ", err)
        end
    end
    return ok_count, err_count
end

function _M.list(event_name)
    return _registry[event_name] or {}
end

function _M._reset_for_test() _registry = {} end

return _M
