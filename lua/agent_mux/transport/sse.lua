-- transport/sse.lua  —  outbound Server-Sent Events writer.
--
-- The full SSE wire format (https://html.spec.whatwg.org/multipage/server-sent-events.html):
--   - Lines are LF-terminated. Multi-line `data:` is allowed; empty line ends the event.
--   - `event:` sets the type the client receives via `evt.type`.
--   - `id:`    sets the last-event-id (used by the client on auto-reconnect).
--   - `retry:` is an optional reconnect hint.
--
-- Why we own the writer: nginx's default response handling buffers; we need
-- explicit `ngx.flush(true)` after each event so the client renders deltas
-- live. `proxy_buffering off` in nginx.conf is the matching setting.

local cjson = require("cjson.safe")

local _M = {}
_M.__index = _M

function _M.new()
    -- Set headers eagerly; nothing should write before us.
    ngx.header["Content-Type"]  = "text/event-stream; charset=utf-8"
    ngx.header["Cache-Control"] = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"  -- belt-and-braces against any upstream proxy
    return setmetatable({ _seq = 0, _closed = false }, _M)
end

-- Emit one event. `payload` is JSON-encoded as `data:`.
function _M:emit(event, payload)
    if self._closed then return end
    self._seq = self._seq + 1
    local body = cjson.encode(payload or {})

    ngx.print("event: ", event, "\n")
    ngx.print("id: ", self._seq, "\n")
    -- Single-line data is sufficient — cjson.encode never inserts newlines.
    ngx.print("data: ", body, "\n\n")
    ngx.flush(true)
end

-- Emit a comment line (kept-alive ping). Clients ignore this; intermediaries
-- that try to time us out see traffic. Use sparingly (every 15-30s).
function _M:ping()
    if self._closed then return end
    ngx.print(": keepalive\n\n")
    ngx.flush(true)
end

-- Mark closed; no further writes. Caller should follow with their own
-- final `done` event before this.
function _M:close()
    self._closed = true
end

return _M
