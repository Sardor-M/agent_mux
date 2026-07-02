-- gateway/mcp_server.lua  —  northbound MCP server (agent_mux as a gateway).
--
-- agent_mux is an MCP *client* southbound (it supervises stdio MCP servers,
-- see tools/mcp.lua). This module makes it an MCP *server* northbound: an
-- MCP client such as Claude Code or Codex connects to agent_mux, and every
-- tool in the aggregated registry (inline + HTTP + all supervised MCP
-- servers) is exposed as one flat tool surface.
--
-- The win: a `tools/call` from any connected client is dispatched through
-- the SAME policy path as the agent loop — API-key auth (at the HTTP edge),
-- per-tool rate limits, pre/post-tool hooks, and metrics — so you get one
-- supervised, observable, policy-enforced MCP endpoint shared across every
-- coding agent you point at it.
--
-- This module is transport-agnostic: `handle(msg, session)` takes one
-- decoded JSON-RPC message and returns a response table (or nil for a
-- notification). server.lua wraps it in the Streamable-HTTP `/mcp` endpoint;
-- bin/agent-mux-mcp bridges stdio to the same endpoint for stdio-only clients.

local jsonrpc    = require("agent_mux.transport.jsonrpc")
local registry   = require("agent_mux.tools.registry")
local dispatcher = require("agent_mux.tools.dispatcher")
local metrics    = require("agent_mux.observability.metrics")

local _M = {}

local SERVER_NAME      = "agent_mux"
local SERVER_VERSION   = "0.3.0-dev"
-- Advertise the same protocol revision our southbound client speaks.
local PROTOCOL_VERSION = "2024-11-05"

-- A no-op SSE sink. dispatcher.run_single emits tool_call/tool_result events
-- for the agent-loop's stream; the gateway has no stream, so we swallow them.
local NULL_SSE = { emit = function() end }

-- Monotonic synthetic tool_use ids so rate-limit / audit keys are unique.
-- Include the worker id so parallel workers don't produce colliding keys.
local _gen = 0
local function gen_id()
    _gen = _gen + 1
    local wid = ngx.worker and ngx.worker.id and ngx.worker.id() or 0
    return "mcpgw-" .. wid .. "-" .. _gen
end

-- Project the registry into MCP `tools/list` shape. Note the field rename:
-- our manifests carry `schema`; MCP wants `inputSchema`.
local function tools_list()
    local out = {}
    for _, m in ipairs(registry.list()) do
        out[#out + 1] = {
            name        = m.name,
            description = m.description,
            inputSchema = m.schema,
        }
    end
    return { tools = out }
end

-- Dispatch one MCP tools/call. Returns (mcp_result | nil, code, message).
local function tools_call(params, session)
    params = params or {}
    if type(params) ~= "table" then
        return nil, jsonrpc.INVALID_PARAMS, "params must be an object"
    end
    local name = params.name
    if type(name) ~= "string" or name == "" then
        return nil, jsonrpc.INVALID_PARAMS, "params.name (string) required"
    end

    local use = { id = gen_id(), name = name, input = params.arguments or {} }
    local ok, out = pcall(dispatcher.run_single, session, use, NULL_SSE)
    if not ok then
        return {
            content = { { type = "text", text = "internal_error: " .. tostring(out) } },
            isError = true,
        }
    end

    -- dispatcher result → MCP content block. is_error maps to isError so the
    -- calling model sees tool failures (rate limits, denials, handler errors)
    -- as tool errors rather than as protocol errors.
    return {
        content = { { type = "text", text = out.content or "" } },
        isError = out.is_error and true or false,
    }
end

-- Handle one decoded JSON-RPC message.
--   returns a response table for a request,
--   returns nil for a notification (no reply on the wire).
-- `session` is a minimal policy carrier: { id = "...", tool_policy = ... }.
function _M.handle(msg, session)
    session = session or { id = "mcp_gateway" }
    if type(msg) ~= "table" or msg.method == nil then
        -- Not a request/notification (e.g. a stray response). Ignore.
        return nil
    end

    local method = msg.method

    -- Notifications have no id and get no response.
    if msg.id == nil then
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = "notification" })
        return nil
    end

    if method == "initialize" then
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = "ok" })
        return jsonrpc.success_response(msg.id, {
            protocolVersion = PROTOCOL_VERSION,
            capabilities    = { tools = { listChanged = false } },
            serverInfo      = { name = SERVER_NAME, version = SERVER_VERSION },
        })

    elseif method == "ping" then
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = "ok" })
        return jsonrpc.success_response(msg.id, {})

    elseif method == "tools/list" then
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = "ok" })
        return jsonrpc.success_response(msg.id, tools_list())

    elseif method == "tools/call" then
        local result, code, emsg = tools_call(msg.params, session)
        if not result then
            metrics.inc("agent_mux_mcp_gateway_requests_total",
                { method = method, outcome = "invalid" })
            return jsonrpc.error_response(msg.id, code, emsg)
        end
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = result.isError and "tool_error" or "ok" })
        return jsonrpc.success_response(msg.id, result)

    else
        metrics.inc("agent_mux_mcp_gateway_requests_total",
            { method = method, outcome = "method_not_found" })
        return jsonrpc.error_response(msg.id, jsonrpc.METHOD_NOT_FOUND,
            "method not found: " .. tostring(method))
    end
end

-- Test / introspection helpers.
_M._tools_list = tools_list
_M._SERVER_NAME = SERVER_NAME

return _M
