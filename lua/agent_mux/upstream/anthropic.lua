-- upstream/anthropic.lua  —  Anthropic Messages API client.
--
-- Streams the upstream response, forwards each text delta to a caller-
-- supplied `on_chunk(piece)` callback, and aggregates the final response
-- (text, stop_reason, usage, tool_use blocks) for the agent loop.
--
-- The Anthropic streaming format is documented at
-- https://docs.anthropic.com/en/api/messages-streaming. Events of interest
-- for v0.1 (turn-only flow):
--
--   message_start          — opening; carries `message.id`, model, initial usage
--   content_block_start    — a new content block (text or tool_use) begins
--   content_block_delta    — a delta inside the current block
--   content_block_stop     — the current block is complete
--   message_delta          — `stop_reason`, `stop_sequence`, output usage
--   message_stop           — stream terminator
--
-- Tool-use blocks accumulate in `response.content` as
-- { type = "tool_use", id, name, input = ... }; the agent loop dispatches
-- them once message_stop is seen. Week-2 territory; the parser already
-- collects them so the loop can plug in cleanly.

local cjson  = require("cjson.safe")
local http   = require("resty.http")
local Stream = require("agent_mux.upstream.stream")

local _M = {}

-- Default endpoint can be overridden via env (useful for the local mock).
local DEFAULT_URL = os.getenv("ANTHROPIC_URL") or "http://127.0.0.1:8080/mock/v1/messages"
local API_VERSION = "2023-06-01"

-- Build the JSON body the API expects. We deliberately pass through whatever
-- the client provided in `messages` and `tools` — the loop is the single
-- place that owns shape mutations.
local function build_body(model, messages, tools, opts)
    return cjson.encode({
        model       = model,
        messages    = messages,
        tools       = (tools and #tools > 0) and tools or nil,
        max_tokens  = (opts and opts.max_tokens) or 1024,
        stream      = true,
        system      = opts and opts.system or nil,
    })
end

-- Per-event handler that mutates the in-progress `response` table.
-- Returns the text piece (if any) so the caller can hand it to on_chunk.
local function apply_event(response, event)
    if event.event == "" or event.event == "message" then return nil end
    local payload, derr = cjson.decode(event.data)
    if not payload then
        ngx.log(ngx.WARN, "anthropic event JSON decode failed: ", derr,
                          " (data=", event.data, ")")
        return nil
    end

    local et = event.event

    if et == "message_start" and payload.message then
        response.id    = payload.message.id
        response.model = payload.message.model
        response.usage = payload.message.usage or response.usage
    elseif et == "content_block_start" then
        local block = payload.content_block or {}
        block.text  = block.text or ""
        response.content[payload.index + 1] = block
    elseif et == "content_block_delta" then
        local block = response.content[payload.index + 1]
        if block and payload.delta then
            if payload.delta.type == "text_delta" and payload.delta.text then
                block.text = block.text .. payload.delta.text
                return payload.delta.text
            elseif payload.delta.type == "input_json_delta" and payload.delta.partial_json then
                -- tool_use blocks stream their JSON arguments here
                block._partial_json = (block._partial_json or "") .. payload.delta.partial_json
            end
        end
    elseif et == "content_block_stop" then
        local block = response.content[payload.index + 1]
        if block and block._partial_json and block.type == "tool_use" then
            local input, ierr = cjson.decode(block._partial_json)
            block.input = input or {}
            if ierr then
                ngx.log(ngx.WARN, "tool_use input JSON decode failed: ", ierr)
            end
            block._partial_json = nil
        end
    elseif et == "message_delta" then
        if payload.delta then
            response.stop_reason   = payload.delta.stop_reason   or response.stop_reason
            response.stop_sequence = payload.delta.stop_sequence or response.stop_sequence
        end
        if payload.usage then
            response.usage = response.usage or {}
            for k, v in pairs(payload.usage) do response.usage[k] = v end
        end
    elseif et == "message_stop" then
        response._terminated = true
    elseif et == "error" then
        response._error = payload
    end
    return nil
end

-- Make a streaming request. Returns the aggregated response on success,
-- or (nil, err) on transport / upstream-error.
--
-- Args:
--   model     string                 e.g. "mock-claude" or "claude-..."
--   messages  array<message>         Anthropic-shaped messages
--   tools     array<tool> | nil      tool schemas (passed through)
--   opts      table                  { url=, api_key=, max_tokens=, system=, on_chunk=fn }
function _M.call(model, messages, tools, opts)
    opts = opts or {}
    local url = opts.url or DEFAULT_URL
    local on_chunk = opts.on_chunk or function(_) end

    local httpc, err = http.new()
    if not httpc then return nil, "http.new: " .. tostring(err) end
    httpc:set_timeout((opts.timeout_ms or 60000))

    local headers = {
        ["Content-Type"]      = "application/json",
        ["Accept"]            = "text/event-stream",
        ["anthropic-version"] = API_VERSION,
    }
    if opts.api_key then headers["x-api-key"] = opts.api_key end

    local res, rerr = httpc:request_uri(url, {
        method  = "POST",
        body    = build_body(model, messages, tools, opts),
        headers = headers,
        -- We need raw streaming; request_uri reads to end which is fine for
        -- the mock and short responses. For long streams, callers can use
        -- the lower-level connect/read_body_chunk API; that lands in week 4
        -- when the bench cares about interleaving. Keep it simple for v0.1.
    })
    if not res then return nil, "request: " .. tostring(rerr) end
    if res.status >= 400 then
        return nil, ("upstream %d: %s"):format(res.status, tostring(res.body):sub(1, 200))
    end

    local response = {
        id           = nil,
        model        = model,
        role         = "assistant",
        content      = {},
        stop_reason  = nil,
        stop_sequence = nil,
        usage        = {},
        _terminated  = false,
    }

    local parser = Stream.new()
    for _, ev in ipairs(parser:feed(res.body or "")) do
        local piece = apply_event(response, ev)
        if piece then on_chunk(piece) end
    end
    for _, ev in ipairs(parser:close()) do
        local piece = apply_event(response, ev)
        if piece then on_chunk(piece) end
    end

    if response._error then
        return nil, "upstream error: " .. cjson.encode(response._error)
    end
    if not response._terminated then
        return nil, "stream ended without message_stop"
    end
    response._terminated = nil

    return response
end

-- Helper exposed for testing — the agent loop uses response.content.
function _M.tool_uses(response)
    local out = {}
    for _, block in ipairs(response.content or {}) do
        if block.type == "tool_use" then out[#out + 1] = block end
    end
    return out
end

return _M
