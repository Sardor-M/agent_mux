-- errors.lua  —  typed errors that translate to either an HTTP response or
-- a typed SSE `error` event, depending on whether headers have been sent.
--
-- The design rule: callers raise *typed* errors with stable codes. Codes
-- are how clients react programmatically; messages are for humans only.

local cjson = require("cjson.safe")

local _M = {}

-- Build a typed error table without responding. Callers can attach this to
-- a tool result, a session record, or a span.
function _M.new(http_status, code, message, extra)
    return {
        http_status = http_status,
        code        = code,
        message     = message,
        extra       = extra,
    }
end

-- Respond with a JSON body and exit. Safe to call from access_by_lua and
-- content_by_lua phases. Will not run if headers are already flushed.
function _M.respond(http_status, code, message, extra)
    if ngx.headers_sent then
        ngx.log(ngx.WARN, "errors.respond after headers sent: ", code, " ", message)
        return ngx.exit(ngx.HTTP_OK)
    end
    ngx.status = http_status
    ngx.header["Content-Type"] = "application/json"
    local body = {
        error = {
            code    = code,
            message = message,
            extra   = extra,
        },
    }
    ngx.say(cjson.encode(body))
    return ngx.exit(http_status)
end

-- Convenience: format any error (typed table or string) as an SSE `error`
-- event payload. Callers do the actual SSE writing via transport.sse.
function _M.to_sse_payload(err)
    if type(err) == "table" then
        return {
            code    = err.code or "internal",
            message = err.message or "unknown",
            extra   = err.extra,
        }
    end
    return { code = "internal", message = tostring(err) }
end

return _M
