-- upstream/stream.lua  —  line-buffered Server-Sent Events parser.
--
-- The SSE wire format (https://html.spec.whatwg.org/multipage/server-sent-events.html):
--
--   event: name\n
--   data:  {"foo": 1}\n
--   id:    42\n
--   \n                       ← blank line ends the event
--
-- Across the network, a single logical event can arrive split across many
-- TCP packets, and a single packet can carry pieces of several events. This
-- parser owns a small buffer, accepts arbitrary chunks, and yields complete
-- {event, data, id} records as they become available.
--
-- We deliberately do not parse `data:` as JSON here — Anthropic's stream
-- has typed events whose data shapes differ. The upstream-specific client
-- (anthropic.lua) decodes per-event-type.

local _M = {}
_M.__index = _M

function _M.new()
    return setmetatable({
        _buf       = "",  -- everything received not yet split into lines
        _cur_event = nil, -- accumulator for the in-progress event
    }, _M)
end

-- Reset accumulator at the start of every event.
local function fresh_event()
    return { event = nil, data = {}, id = nil }
end

-- Process one logical SSE field line. Empty input means "event terminator".
local function parse_field(self, line)
    if line == "" then
        -- end-of-event marker — flush if anything was accumulated
        if self._cur_event then
            local ev = self._cur_event
            self._cur_event = nil
            return {
                event = ev.event or "message",
                data  = table.concat(ev.data, "\n"),
                id    = ev.id,
            }
        end
        return nil
    end

    -- Comment lines start with ":" — ignore (used for keepalive pings).
    if line:sub(1, 1) == ":" then return nil end

    -- field[: optional space]value
    local colon = line:find(":", 1, true)
    local field, value
    if not colon then
        field, value = line, ""
    else
        field = line:sub(1, colon - 1)
        value = line:sub(colon + 1)
        if value:sub(1, 1) == " " then value = value:sub(2) end
    end

    self._cur_event = self._cur_event or fresh_event()
    if field == "event" then
        self._cur_event.event = value
    elseif field == "data" then
        table.insert(self._cur_event.data, value)
    elseif field == "id" then
        self._cur_event.id = value
    end
    -- "retry" and unknown fields silently ignored, per spec.
    return nil
end

-- Feed a chunk of bytes (any size, any boundaries). Returns an array of
-- complete events that became available — possibly empty.
function _M:feed(chunk)
    local events = {}
    self._buf = self._buf .. (chunk or "")

    while true do
        local nl = self._buf:find("\n", 1, true)
        if not nl then break end

        local line = self._buf:sub(1, nl - 1)
        self._buf = self._buf:sub(nl + 1)

        -- Tolerate \r\n line endings (some servers, some proxies).
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end

        local ev = parse_field(self, line)
        if ev then events[#events + 1] = ev end
    end

    return events
end

-- Drain anything still in the buffer at end-of-stream.
function _M:close()
    local out = {}
    for _, ev in ipairs(self:feed("\n")) do out[#out + 1] = ev end
    return out
end

return _M
