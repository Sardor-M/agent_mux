-- server.lua  —  request phase glue.
--
-- nginx wires us up via `access_by_lua_block`, `content_by_lua_block`, and
-- `log_by_lua_block` in conf/nginx.conf. Each phase function is small and
-- delegates to the right module.
--
-- Phase contract (week 1):
--   access()         — parse + validate the request body, attach to ngx.ctx.
--   content()        — open SSE stream + run AgentLoop.
--   log_phase()      — one structured log line per request.
--   handle_session() — non-streaming session introspection / cancel.

local cjson       = require("cjson.safe")
local errors      = require("agent_mux.errors")
local log         = require("agent_mux.observability.log")
local sse_mod     = require("agent_mux.transport.sse")
local AgentLoop   = require("agent_mux.agent_loop")
local store       = require("agent_mux.session.store")
local concurrency = require("agent_mux.session.concurrency")
local auth_req    = require("agent_mux.policy.auth_request")
local ip_ratelimit = require("agent_mux.policy.ip_ratelimit")

local _M = {}

-- Validate the minimum shape; reject early so we fail loud and cheap.
local function parse_request_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw or raw == "" then
        local f = ngx.req.get_body_file()
        if f then
            local fh = io.open(f, "rb")
            if fh then raw = fh:read("*a"); fh:close() end
        end
    end
    if not raw or raw == "" then
        return nil, "empty body"
    end
    local body, derr = cjson.decode(raw)
    if not body then return nil, "json: " .. tostring(derr) end
    if type(body.messages) ~= "table" or #body.messages == 0 then
        return nil, "messages: array required and non-empty"
    end
    if type(body.model) ~= "string" or body.model == "" then
        return nil, "model: string required"
    end
    return body
end

-- Application-level body cap. Stricter than nginx's client_max_body_size
-- (4 MB by default) so a pathological caller posting a huge message
-- history is rejected before we waste cycles parsing JSON.
local MAX_BODY_BYTES = tonumber(os.getenv("AGENT_MUX_MAX_BODY_BYTES")) or (256 * 1024)

-- Phase 1: access.
function _M.access()
    ngx.ctx.started_at_ms = ngx.now() * 1000

    if ngx.req.get_method() ~= "POST" then
        return errors.respond(405, "method_not_allowed", ngx.req.get_method())
    end

    -- Body size pre-check. Content-Length is best-effort (chunked requests
    -- omit it); for chunked, nginx's client_max_body_size is the hard cap.
    local cl = tonumber(ngx.req.get_headers()["Content-Length"])
    if cl and cl > MAX_BODY_BYTES then
        return errors.respond(413, "request_too_large",
            string.format("body %d bytes exceeds %d byte cap", cl, MAX_BODY_BYTES))
    end

    -- Request-level auth (API key). Runs first so an unauthenticated
    -- caller never causes any Redis writes or upstream calls.
    local auth_ok, auth_reason = auth_req.check()
    if not auth_ok then
        return errors.respond(401, "unauthorized", auth_reason)
    end

    -- Per-IP rate limit. After auth so we don't waste a Redis hit on a
    -- request we'd reject anyway. Returns 429 with Retry-After header
    -- per the HTTP spec.
    local ip_ok, retry_ms = ip_ratelimit.check()
    if not ip_ok then
        ngx.header["Retry-After"] = math.ceil(retry_ms / 1000)
        return errors.respond(429, "ip_rate_limited",
            ("retry after %d ms"):format(retry_ms))
    end

    local body, err = parse_request_body()
    if not body then
        return errors.respond(400, "bad_request", err)
    end

    -- agent_id is optional metadata for now; extracted from header or body.
    body.agent_id = ngx.req.get_headers()["X-Agent-Id"] or (body.metadata and body.metadata.agent_id)
    body.org_id   = ngx.req.get_headers()["X-Org-Id"]   or (body.metadata and body.metadata.org_id)

    local session, serr = store.create(body)
    if not session then
        return errors.respond(500, "session_create_failed", serr)
    end

    -- Per-org concurrency cap. If full, the session doc is left with
    -- status="running" but no slot — release is idempotent so log_phase
    -- won't break. We immediately mark it errored before responding
    -- so the user sees a clean state.
    local claimed, current = concurrency.claim(session)
    if not claimed then
        store.error(session, "concurrency_cap_exceeded")
        return errors.respond(429, "concurrency_cap",
            string.format("org has %d concurrent sessions; cap reached", current))
    end

    ngx.ctx.session = session
end

-- Phase 2: content. SSE stream + agent loop.
function _M.content()
    local session = ngx.ctx.session
    if not session then
        -- access() should have populated this; defensive guard.
        return errors.respond(500, "internal", "session missing in ctx")
    end

    -- Expose session_id so clients can introspect / resume.
    ngx.header["X-Session-Id"] = session.id

    local sse = sse_mod.new()
    local loop = AgentLoop.new(session)

    local ok, run_err = pcall(loop.run, loop, sse)
    if not ok then
        log.error("agent_loop_crashed", { session_id = session.id, err = tostring(run_err) })
        sse:emit("error", errors.to_sse_payload({
            code    = "internal",
            message = tostring(run_err),
        }))
        store.error(session, tostring(run_err))
    end
    sse:emit("end", {})
    sse:close()
end

-- Phase 3: log. Always runs, even on early exit. Keep cheap.
function _M.log_phase()
    local started = ngx.ctx.started_at_ms
    if ngx.ctx.session then
        -- Best-effort release. Idempotent — if the slot wasn't held (e.g.
        -- concurrency cap rejected the request), this is a no-op.
        concurrency.release(ngx.ctx.session)
    end
    if started then
        log.info("request", {
            uri        = ngx.var.uri,
            status     = ngx.status,
            session_id = ngx.ctx.session and ngx.ctx.session.id,
            latency_ms = ngx.now() * 1000 - started,
        })
    end
end

-- Access guard for the session-introspection routes. Sessions hold the
-- full message history (prompts, tool results — potentially PII) and can be
-- cancelled, so the same API-key auth and per-IP rate limit that protect
-- /v1/agents must apply here. Without this, anyone who can reach the port
-- could read or cancel any session whose id they can guess.
function _M.session_access()
    local auth_ok, auth_reason = auth_req.check()
    if not auth_ok then
        return errors.respond(401, "unauthorized", auth_reason)
    end

    local ip_ok, retry_ms = ip_ratelimit.check()
    if not ip_ok then
        ngx.header["Retry-After"] = math.ceil(retry_ms / 1000)
        return errors.respond(429, "ip_rate_limited",
            ("retry after %d ms"):format(retry_ms))
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
        local s, err = store.load(session_id)
        if not s then
            if err == "not_found" then
                return errors.respond(404, "not_found", "session " .. session_id)
            end
            return errors.respond(500, "session_load_failed", err)
        end
        ngx.header["Content-Type"] = "application/json"
        ngx.say(store.to_json(s))
        return
    elseif method == "DELETE" then
        -- Best-effort: load to confirm existence; signal cancel.
        local s, err = store.load(session_id)
        if not s then
            if err == "not_found" then
                return errors.respond(404, "not_found", "session " .. session_id)
            end
            return errors.respond(500, "session_load_failed", err)
        end
        if s.status ~= "running" then
            -- Already terminal — idempotent response.
            ngx.header["Content-Type"] = "application/json"
            ngx.say(string.format(
                '{"status":"%s","note":"session already terminal"}', s.status))
            return
        end
        local ok, serr = store.signal_cancel(session_id)
        if not ok then
            return errors.respond(500, "signal_failed", serr)
        end
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"status":"cancelling","note":"signal sent; loop will abort at next turn boundary"}')
        return
    else
        return errors.respond(405, "method_not_allowed", method)
    end
end

return _M
