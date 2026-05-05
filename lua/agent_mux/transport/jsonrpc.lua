-- transport/jsonrpc.lua  —  JSON-RPC 2.0 framing helpers.
--
-- Shapes from https://www.jsonrpc.org/specification:
--
--   request:       { jsonrpc = "2.0", id = N, method = "...", params = {...} }
--   notification:  { jsonrpc = "2.0", method = "...", params = {...} }       -- no id, no response
--   success resp:  { jsonrpc = "2.0", id = N, result = ... }
--   error resp:    { jsonrpc = "2.0", id = N, error = { code, message, data? } }
--
-- This module is **transport-agnostic** — it doesn't know about stdio,
-- pipes, sockets, or HTTP. Encode produces a string; decode parses one.
-- The MCP client (tools/mcp.lua) handles the wire-level framing
-- (newline-delimited JSON for stdio).

local cjson = require("cjson.safe")

local _M = {}
_M.JSONRPC_VERSION = "2.0"

-- Standard JSON-RPC error codes (https://www.jsonrpc.org/specification#error_object).
_M.PARSE_ERROR      = -32700
_M.INVALID_REQUEST  = -32600
_M.METHOD_NOT_FOUND = -32601
_M.INVALID_PARAMS   = -32602
_M.INTERNAL_ERROR   = -32603

-- Per-process monotonic id generator. We never reuse ids in the same
-- worker, so correlating responses to in-flight requests is trivial.
local _next_id = 0
local function next_id()
    _next_id = _next_id + 1
    return _next_id
end

function _M.request(method, params, id)
    return {
        jsonrpc = _M.JSONRPC_VERSION,
        id      = id or next_id(),
        method  = method,
        params  = params,
    }
end

function _M.notification(method, params)
    return {
        jsonrpc = _M.JSONRPC_VERSION,
        method  = method,
        params  = params,
    }
end

function _M.success_response(id, result)
    return {
        jsonrpc = _M.JSONRPC_VERSION,
        id      = id,
        result  = result,
    }
end

function _M.error_response(id, code, message, data)
    return {
        jsonrpc = _M.JSONRPC_VERSION,
        id      = id,
        error   = { code = code, message = message, data = data },
    }
end

function _M.encode(msg) return cjson.encode(msg) end

function _M.decode(blob)
    local v, err = cjson.decode(blob)
    if not v then return nil, "parse: " .. tostring(err) end
    if type(v) ~= "table" then return nil, "not a JSON object" end
    if v.jsonrpc ~= _M.JSONRPC_VERSION then
        return nil, "missing or bad jsonrpc version"
    end
    return v
end

-- Categorise a decoded message. Useful for the MCP client's read loop.
function _M.kind(msg)
    if msg.method then
        return msg.id and "request" or "notification"
    end
    if msg.id ~= nil then
        if msg.error then return "error_response" end
        if msg.result ~= nil then return "success_response" end
    end
    return "unknown"
end

function _M.is_response(msg)
    local k = _M.kind(msg)
    return k == "success_response" or k == "error_response"
end

return _M
