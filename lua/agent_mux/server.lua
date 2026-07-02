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

-- POST /mcp  — northbound MCP gateway (Streamable-HTTP transport).
--
-- An MCP client (Claude Code, Codex) POSTs JSON-RPC here; we route each
-- message through gateway.mcp_server and reply with a single JSON body.
-- A batch (JSON array) is processed in order and answered with an array of
-- the responses that have ids (notifications produce no response). API-key
-- auth is applied at this edge exactly like /v1/agents.
function _M.mcp_gateway()
    if ngx.req.get_method() ~= "POST" then
        return errors.respond(405, "method_not_allowed", ngx.req.get_method())
    end

    local auth_ok, auth_reason = auth_req.check()
    if not auth_ok then
        return errors.respond(401, "unauthorized", auth_reason)
    end

    local cl = tonumber(ngx.req.get_headers()["Content-Length"])
    if cl and cl > MAX_BODY_BYTES then
        return errors.respond(413, "request_too_large",
            string.format("body %d bytes exceeds %d byte cap", cl, MAX_BODY_BYTES))
    end

    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if (not raw or raw == "") then
        local bf = ngx.req.get_body_file()
        if bf then
            local fh = io.open(bf, "rb")
            if fh then raw = fh:read("*a"); fh:close() end
        end
    end
    if not raw or raw == "" then
        return errors.respond(400, "bad_request", "empty body")
    end

    local decoded, derr = cjson.decode(raw)
    if decoded == nil then
        return errors.respond(400, "parse_error", tostring(derr))
    end
    if type(decoded) ~= "table" then
        return errors.respond(400, "bad_request", "JSON-RPC request must be an object or array")
    end

    local gateway = require("agent_mux.gateway.mcp_server")
    -- Stable-ish session id so per-tool rate-limit buckets are shared across
    -- a client's calls rather than reset every request. Validate the header
    -- value so malformed ids don't propagate into Redis keys or logs.
    local session_id = ngx.req.get_headers()["X-Session-Id"] or "mcp_gateway"
    if not session_id:match("^[A-Za-z0-9_-]+$") or #session_id > 128 then
        session_id = "mcp_gateway"
    end
    local session = {
        id          = session_id,
        tool_policy = nil,
    }

    ngx.header["Content-Type"] = "application/json"

    -- Batch vs single. A JSON-RPC batch is an array; a non-empty array has a
    -- [1] element. An empty array [] decodes to {} (#decoded == 0) with no
    -- integer keys — treat it as a batch that yields no responses (HTTP 202).
    if decoded[1] ~= nil or #decoded == 0 then
        local out = {}
        for _, msg in ipairs(decoded) do
            local resp = gateway.handle(msg, session)
            if resp ~= nil then out[#out + 1] = resp end
        end
        if #out == 0 then
            -- All notifications — HTTP 202, no JSON-RPC body.
            ngx.status = 202
            return ngx.exit(202)
        end
        ngx.say(cjson.encode(out))
        return
    end

    local resp = gateway.handle(decoded, session)
    if resp == nil then
        -- Single notification — accepted, no body.
        ngx.status = 202
        return ngx.exit(202)
    end
    ngx.say(cjson.encode(resp))
end

-- Right-pad to a column width (always leaves at least one trailing space).
local function pad(s, n)
    s = tostring(s == nil and "-" or s)
    if #s >= n then return s .. " " end
    return s .. string.rep(" ", n - #s)
end

-- Render mcp.status() as a fixed-width text table for the CLI status view.
local function mcp_status_text(status)
    local lines = {}
    lines[#lines + 1] = ("MCP SERVERS (%d)"):format(#status)
    lines[#lines + 1] = pad("NAME", 16) .. pad("STATUS", 8) .. pad("PID", 8) ..
        pad("RESTARTS", 10) .. pad("TOOLS", 7) .. pad("INFLIGHT", 10) ..
        pad("CALLS", 8) .. pad("ERRORS", 8) .. "LAST(ms)"
    if #status == 0 then
        lines[#lines + 1] = "(no MCP servers configured — set AGENT_MUX_MCP_FILE)"
    end
    for _, s in ipairs(status) do
        local state = s.alive and "up" or "DOWN"
        local last  = s.last_latency_ms and string.format("%.1f", s.last_latency_ms) or "-"
        lines[#lines + 1] = pad(s.name, 16) .. pad(state, 8) .. pad(s.pid or "-", 8) ..
            pad(s.restarts, 10) .. pad(s.tool_count, 7) .. pad(s.in_flight, 10) ..
            pad(s.calls_total, 8) .. pad(s.errors_total, 8) .. last
    end
    return table.concat(lines, "\n") .. "\n"
end

-- GET /v1/mcp/servers  — supervised MCP server status.
-- Default: JSON. `?format=text`: a rendered table (so the CLI needs no jq).
function _M.mcp_status()
    if ngx.req.get_method() ~= "GET" then
        return errors.respond(405, "method_not_allowed", ngx.req.get_method())
    end
    local mcp    = require("agent_mux.tools.mcp")
    local status = mcp.status()
    local args   = ngx.req.get_uri_args()

    if args.format == "text" then
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.print(mcp_status_text(status))
        return
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ servers = status, count = #status }))
end

-- Access guard for the session-introspection routes. Sessions hold the
-- full message history (prompts, tool results — potentially PII) and can be
-- cancelled, so the same API-key auth and per-IP rate limit that protect
-- /v1/agents must apply here. Without this, anyone who can reach the port
-- could read or cancel any session whose id they can guess.
function _M.session_access()
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "DELETE" then
        return errors.respond(405, "method_not_allowed", method)
    end

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
