-- server.lua  —  request phase glue.
--
-- nginx wires us up via `access_by_lua_block`, `content_by_lua_block`, and
-- `log_by_lua_block` in conf/nginx.conf. Each phase function is small and
-- delegates to the right module.
--
-- Phase contract:
--   access()         — validate, load/create session, claim concurrency slot.
--                      May respond with 4xx/429 and exit before content phase.
--   content()        — SSE stream + run AgentLoop coroutine.
--   log_phase()      — emit final span, flush metrics, release concurrency slot.
--   handle_session() — non-streaming session introspection / cancel.

local errors = require("agent_mux.errors")
local log    = require("agent_mux.observability.log")

local _M = {}

-- Phase 1: access. Cheap pre-flight checks; nothing streaming yet.
-- Filled in during week 1 (auth, session create/resume, budget check).
function _M.access()
    -- Stub for v0.1 scaffolding. Until the agent loop lands, accept the
    -- request and let content() return a typed "not_implemented" error.
    ngx.ctx.started_at_ms = ngx.now() * 1000
end

-- Phase 2: content. Where the SSE stream and the agent loop live.
function _M.content()
    -- TODO(week 1): construct AgentLoop coroutine; stream transcript.
    return errors.respond(
        501,
        "not_implemented",
        "agent loop arrives in week 1 — see docs/IMPLEMENTATION_PLAN.md §15"
    )
end

-- Phase 3: log. Always runs, even on early exit. Keep it cheap.
function _M.log_phase()
    local started = ngx.ctx.started_at_ms
    if started then
        log.info("request", {
            uri        = ngx.var.uri,
            status     = ngx.status,
            latency_ms = ngx.now() * 1000 - started,
        })
    end
end

-- /v1/sessions/:id  — non-streaming. GET introspects, DELETE cancels.
function _M.handle_session()
    local session_id = ngx.var.session_id
    if not session_id or session_id == "" then
        return errors.respond(400, "bad_request", "missing session_id")
    end

    local method = ngx.req.get_method()
    if method == "GET" then
        return errors.respond(501, "not_implemented", "session introspection arrives in week 1")
    elseif method == "DELETE" then
        return errors.respond(501, "not_implemented", "session cancellation arrives in week 3")
    else
        return errors.respond(405, "method_not_allowed", method)
    end
end

return _M
