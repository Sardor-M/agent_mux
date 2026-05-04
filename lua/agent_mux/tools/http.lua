-- tools/http.lua  —  HTTP tool handler adapter.
--
-- Lets a tool live as a microservice. AgentMux POSTs the LLM-supplied
-- input as JSON to the configured URL and forwards the response body
-- back to the model as the tool_result content.
--
-- Manifest file (JSON) format:
--
--   {
--     "tools": [
--       {
--         "name": "search",
--         "description": "...",
--         "schema": { ... },
--         "url": "http://127.0.0.1:8080/mock/tools/search",
--         "method": "POST",            // optional, defaults to POST
--         "timeout_ms": 5000,          // optional
--         "headers": { ... }           // optional, request headers
--       },
--       ...
--     ]
--   }
--
-- Service contract — a tool service receives `{ "input": <whatever the
-- model produced> }` and replies with one of:
--
--   200 { "content": "..." }                     → success
--   200 { "content": "...", "is_error": true }   → typed error
--   non-2xx                                       → typed transport error

local cjson    = require("cjson.safe")
local http     = require("resty.http")
local registry = require("agent_mux.tools.registry")

local _M = {}

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local body = f:read("*a")
    f:close()
    return body
end

-- Build a `run` closure for one tool. Closes over url/method/headers/timeout.
local function make_runner(spec)
    local url        = assert(spec.url,  "http tool: url required")
    local method     = (spec.method or "POST"):upper()
    local timeout_ms = spec.timeout_ms or 5000
    local headers    = spec.headers or {}
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    headers["Accept"]       = headers["Accept"]       or "application/json"

    return function(input, _ctx)
        local httpc, err = http.new()
        if not httpc then
            return { is_error = true, content = "http.new: " .. tostring(err) }
        end
        httpc:set_timeout(timeout_ms)

        local body = cjson.encode({ input = input })

        local res, rerr = httpc:request_uri(url, {
            method  = method,
            body    = body,
            headers = headers,
            keepalive_timeout = 30000,
            keepalive_pool    = 16,
        })
        if not res then
            return { is_error = true, content = "transport: " .. tostring(rerr) }
        end

        if res.status >= 400 then
            return {
                is_error = true,
                content  = ("http_%d: %s"):format(res.status,
                    tostring(res.body):sub(1, 200)),
            }
        end

        -- Try to decode JSON; if the service returned plain text, use it as-is.
        local decoded = cjson.decode(res.body or "")
        if type(decoded) == "table" then
            return {
                is_error = decoded.is_error and true or nil,
                content  = decoded.content ~= nil and tostring(decoded.content)
                                                 or  cjson.encode(decoded),
            }
        end
        return { content = res.body or "" }
    end
end

function _M.register_spec(spec)
    spec.run     = make_runner(spec)
    spec._origin = "http"
    return registry.register(spec)
end

-- Load a manifest file containing a `tools` array; register each entry.
function _M.load_manifest(path)
    local raw, err = read_file(path)
    if not raw then return nil, "read " .. path .. ": " .. tostring(err) end
    local doc, derr = cjson.decode(raw)
    if not doc then return nil, "decode " .. path .. ": " .. tostring(derr) end
    if type(doc.tools) ~= "table" then
        return nil, "manifest missing 'tools' array"
    end
    local registered = {}
    for _, spec in ipairs(doc.tools) do
        local m, rerr = pcall(_M.register_spec, spec)
        if not m then
            ngx.log(ngx.WARN, "http tool register failed: ", rerr)
        else
            registered[#registered + 1] = spec
        end
    end
    return registered
end

_M._make_runner = make_runner
return _M
